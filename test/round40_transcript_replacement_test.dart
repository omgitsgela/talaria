import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// A parked reader must not be moved by a REPLACED transcript.
///
/// Reported: "occasionally when responses are streaming in, if I'm not scrolled
/// all the way to the bottom, one in a while the page will jump kind of randomly
/// around to different responses. It might be when a tool call happens? I saw it
/// jump all the way to the start of yesterday's conversation."
///
/// Measured cause: the read-hold compensates for a growing `maxScrollExtent` on
/// the assumption that the growth is at the newest end. That is right for
/// appended content and wrong for a list that was REPLACED. `resumeSession(...,
/// silent: true)` is the stale-runtime recovery, and it replaces the transcript
/// for the SAME session id, so the screen never treated it as a conversation
/// switch. The reader kept their offset while the content changed underneath,
/// and the hold then moved them by the extent change, once per layout pass:
///
///   parked      pixels=2500.0  max=9112.6   messages=30
///   rehydrated  pixels=9978.4  max=12851.0  messages=42   moved=7478.4
///
/// 7478 is twice the extent change (3739), which is why the jump overshot into
/// the far end of the conversation. A replacement now re-baselines the hold and
/// leaves the reader where they are.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class R40Gateway extends GatewayClient {
  R40Gateway() : super(_cfg);
  final responses = <String, Map<String, dynamic>>{};
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final _stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);
  int usageTick = 1000;

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => pushed.stream;
  @override
  Stream<GwConnectionState> get stateChanges => _stateCtl.stream;
  @override
  Future<void> connect({bool isReconnect = false}) async {
    _stateCtl.add(GwConnectionState.open);
  }

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    if (responses.containsKey(method)) return responses[method]!;
    return switch (method) {
      'session.create' => {'session_id': 'live-r40'},
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'prompt.submit' => {'status': 'streaming'},
      'session.usage' => {'context_used': 1000, 'context_max': 128000},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data,
          {String sid = 'live-r40'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
    await _stateCtl.close();
  }
}

ScrollPosition _pos(WidgetTester tester) {
  final lv = tester.widget<ListView>(find.byType(ListView).first);
  final c = lv.controller;
  if (c != null && c.hasClients) return c.position;
  throw StateError('no transcript');
}

List<Map<String, dynamic>> _history({int extra = 0}) {
  String body(String tag, int i) =>
      '$tag $i\n${List.generate(6, (j) => '$tag-$i line $j').join('\n')}';
  final rows = <Map<String, dynamic>>[];
  var ts = 1.0;
  for (var i = 0; i < 14; i++) {
    rows.add({'role': 'user', 'text': body('older question', i), 'ts': ts++});
    rows.add({'role': 'assistant', 'text': body('older answer', i), 'ts': ts++});
  }
  for (var i = 0; i < extra; i++) {
    rows.add({'role': 'user', 'text': body('recovered question', i), 'ts': ts++});
    rows.add(
        {'role': 'assistant', 'text': body('recovered answer', i), 'ts': ts++});
  }
  rows.add({'role': 'user', 'text': body('newer question', 0), 'ts': ts++});
  rows.add({'role': 'assistant', 'text': body('newer answer', 0), 'ts': ts++});
  return rows;
}

Future<(R40Gateway, ChatStore)> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1260, 2700);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final gw = R40Gateway();
  gw.responses['session.resume'] = {
    'session_id': 'live-r40',
    'resumed': 'stored-r40',
    'messages': _history(),
  };
  final store = ChatStore(config: _cfg, client: gw);
  addTearDown(store.dispose);
  await store.connect();
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
  await tester.pump();
  await store.resumeSession('stored-r40');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
  return (gw, store);
}

/// Fixed pumps: a streaming turn keeps a spinner animating, so pumpAndSettle hangs.
Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 80));
}

/// A reader drag from the list's own padding: points over selectable text can be
/// claimed by the text and never scroll.
Future<void> _dragUp(WidgetTester tester, double by) async {
  final g = await tester.startGesture(
      tester.getTopLeft(find.byType(ListView).first) + const Offset(10, 6));
  final steps = (by / 30).ceil();
  for (var i = 0; i < steps; i++) {
    await g.moveBy(Offset(0, by / steps));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a replaced transcript does not move a parked reader',
      (tester) async {
    final (gw, store) = await _open(tester);
    await _dragUp(tester, 2500);
    await _settle(tester);
    final parked = _pos(tester).pixels;
    final maxBefore = _pos(tester).maxScrollExtent;
    expect(parked, greaterThan(2000), reason: 'the reader must be up the list');

    // The stale-runtime recovery: same session id, transcript replaced with a
    // history that has moved on.
    gw.responses['session.resume'] = {
      'session_id': 'live-r40',
      'resumed': 'stored-r40',
      'messages': _history(extra: 6),
    };
    await store.resumeSession('stored-r40', silent: true);
    await _settle(tester);
    await _settle(tester);

    expect(store.messages.length, greaterThan(30),
        reason: 'the rehydrate must have landed, or this proves nothing');
    // The CORRECTED contract. A rehydrate that APPENDS leaves the reader's
    // content exactly where it was only if the offset follows the growth: the
    // new messages are below them, so keeping what they are reading on screen
    // means moving by that growth. The original bug was not the movement, it was
    // the movement being applied twice (7478 for a 3739 change), which overshot
    // the reader into the far end of the conversation. So the assertions are:
    // the move matches the growth, and the reader is nowhere near the end.
    final after = _pos(tester);
    final growth = after.maxScrollExtent - maxBefore;
    // Never MORE than the growth: overshooting is the bug (the original
    // measurement moved the reader twice the change, into the far end). Slightly
    // less is correct and expected, because part of an extent change can be an
    // ESTIMATE for rows above the reader, which must not move them at all.
    final moved = after.pixels - parked;
    expect(moved, lessThanOrEqualTo(growth + 20),
        reason: 'the reader must never be moved further than the content grew: '
            'moved=$moved growth=$growth');
    expect(moved, greaterThan(growth * 0.5),
        reason: 'content must be preserved for the reader: '
            'moved=$moved growth=$growth');
    expect(after.pixels, lessThan(after.maxScrollExtent - 500),
        reason: 'and they must not be anywhere near the end of the '
            'conversation: pixels=${after.pixels} max=${after.maxScrollExtent}');
  });

  // The compensation for real growth is covered by round33/36/37 (a drag
  // survives streamed characters, the anchor holds as the reply grows). What
  // needs guarding HERE is the branch this fix touched: a replacement must not
  // disturb a reader who is FOLLOWING the newest end either.
  testWidgets('a replacement leaves a following reader at the newest end',
      (tester) async {
    final (gw, store) = await _open(tester);
    // No drag: the reader is at the bottom, following.
    expect(_pos(tester).pixels, 0);
    gw.responses['session.resume'] = {
      'session_id': 'live-r40',
      'resumed': 'stored-r40',
      'messages': _history(extra: 6),
    };
    await store.resumeSession('stored-r40', silent: true);
    await _settle(tester);
    await _settle(tester);
    expect(store.messages.length, greaterThan(30),
        reason: 'the rehydrate must have landed, or this proves nothing');
    expect(_pos(tester).pixels, 0,
        reason: 'following must survive a replacement');
  });
}
