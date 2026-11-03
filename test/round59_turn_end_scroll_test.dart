import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// The transcript must not snap away from a parked reader when a turn FINISHES.
///
/// Angela's report on 1.4.0: "the conversation history snaps to the top when a
/// new chat conversation finishes."
///
/// Mechanism, MEASURED with the instrumentation this project's scroll contract
/// demands (print pixels/maxScrollExtent per event, never theorize):
///
///   parked       pixels=1746  max=77645   streaming=true
///   metrics      pixels=1746  max=14908   <- extent SHRANK at turn end
///   hold jump    target=-60991            <- the shrink compensation fired
///   onScrollEnd  re-arm at -60991         <- garbage read as user intent
///   follow jump  -> 0                     <- pinned to the newest end
///
/// Three links, all in one place:
/// 1. A turn END lands the biggest shrink of the whole session: the streamed
///    bubble is replaced by the canonical final text and the deferred history
///    merge rewrites rows, and in a lazy list maxScrollExtent is an ESTIMATE
///    that collapses as big rows are re-measured.
/// 2. The read-hold's shrink rule was gated on `store.streaming` — it expired
///    at the exact moment the shrink happened, so the hold applied a delta of
///    -62737 and jumped the reader to a NEGATIVE offset. The #19 guard only
///    refuses the UPPER clamp (`target > max`); the lower side went through.
/// 3. `_onScrollEnd` re-arms the follow when `pixels <= 48`. A negative offset
///    passes that test, so the framework's own garbage offset was read as the
///    user deliberately settling at the newest end — and every later repaint
///    pinned the view there.
///
/// Rules (each cuts one link):
/// - The hold ignores a SHRINK always, not only while streaming. Re-baseline
///   instead of compensating; the offset is anchored at the newest end, so
///   content shrinking above the viewport does not move what is on screen.
/// - A hold move that lands OUTSIDE [0, maxScrollExtent] does not exist, which
///   means the measurement is stale: hold still (already re-baselined).
/// - `_onScrollEnd` re-arms only for an offset genuinely inside the
///   near-bottom band; an out-of-range offset is plumbing, never intent.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class SGateway extends GatewayClient {
  SGateway() : super(_cfg);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  Map<String, dynamic> resumeReply = const {};
  List<Map<String, dynamic>> historyRows = const [];

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => pushed.stream;
  @override
  Stream<GwConnectionState> get stateChanges => const Stream.empty();
  @override
  Future<void> connect({bool isReconnect = false}) async {}

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    return switch (method) {
      'session.resume' => resumeReply,
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'session.active_list' => {
          'sessions': [
            {'id': 'live-s', 'session_key': 'stored-s'}
          ]
        },
      'prompt.submit' => {'status': 'streaming'},
      'session.history' => {'messages': historyRows},
      'session.usage' => {'context_used': 1, 'context_max': 2},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data, {String sid = 'live-s'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
  }
}

List<Map<String, dynamic>> _history(int pairs) {
  String body(String tag, int i) =>
      '$tag $i\n${List.generate(6, (j) => '$tag-$i line $j').join('\n')}';
  final rows = <Map<String, dynamic>>[];
  var ts = 1.0;
  for (var i = 0; i < pairs; i++) {
    rows.add({'role': 'user', 'text': body('question', i), 'ts': ts++});
    rows.add({'role': 'assistant', 'text': body('answer', i), 'ts': ts++});
  }
  return rows;
}

ScrollPosition _pos(WidgetTester tester) {
  final lv = tester.widget<ListView>(find.byType(ListView).first);
  final c = lv.controller;
  if (c != null && c.hasClients) return c.position;
  throw StateError('no transcript');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a parked reader stays parked when the turn finishes',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1260, 2700);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final gw = SGateway();
    gw.resumeReply = {
      'session_id': 'live-s',
      'resumed': 'stored-s',
      'messages': _history(20),
    };
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
    await tester.pump();
    await store.resumeSession('stored-s');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // A turn streams a big reply, then seals a bubble and finishes; the
    // deferred history merge rewrites the rows (the extent collapses).
    gw.emit('message.start', {});
    await store.send('a live question');
    gw.emit('message.delta', {
      'text': List.generate(40, (j) => 'streamed line $j of the answer')
          .join('\n'),
    });
    await tester.pump(const Duration(milliseconds: 60));

    // The reader parks mid-conversation with a REAL drag (a programmatic
    // jumpTo is not user intent and would exercise the wrong path).
    final gesture = await tester.startGesture(
        tester.getTopLeft(find.byType(ListView).first) + const Offset(10, 6));
    for (var step = 0; step < 10; step++) {
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final parked = _pos(tester).pixels;
    expect(parked, greaterThan(48),
        reason: 'the reader must actually be away from the newest end');

    // THE TURN FINISHES.
    gw.emit('message.interim',
        {'text': 'interim note', 'already_streamed': false});
    await tester.pump(const Duration(milliseconds: 60));
    gw.emit('message.complete', {
      'final_response':
          List.generate(40, (j) => 'final line $j of the answer').join('\n'),
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    // And the deferred history merge lands (sessions.changed arms the pull).
    gw.historyRows = _history(21); // includes the finished turn
    gw.emit('sessions.changed', {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(milliseconds: 80));

    final pos = _pos(tester);
    final p = pos.pixels;
    final max = pos.maxScrollExtent;
    // ignore: avoid_print
    print('FINAL pixels=$p max=$max parked=$parked streaming=${store.streaming}');
    expect(p, greaterThan(48),
        reason: 'the view must NOT snap to the newest end when a turn ends: '
            'parked=$parked now=$p max=$max');
    expect(p, greaterThanOrEqualTo(0),
        reason: 'the reader must never be moved to an out-of-range offset — '
            'that garbage is what re-armed the follow latch against intent');
    expect(max - p, greaterThan(100),
        reason: 'and not thrown to the oldest end either: p=$p max=$max');
  });
}
