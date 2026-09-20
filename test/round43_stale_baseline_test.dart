import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// A parked reader must never be teleported to the beginning of the conversation.
///
/// Reported: "When a response is streaming in, if you are browsing the
/// conversation in the middle somewhere, the moment a new thinking trace starts,
/// the conversation view will jump all the way to the top of the conversation,
/// instead of staying where you're currently reading." Asked to disambiguate:
/// it scrolls to the top IMMEDIATELY, the actual beginning of the conversation.
///
/// Mechanism, and it is arithmetic rather than a guess. The read-hold does:
///
///   final delta = np.maxScrollExtent - ref;              // ref = _pinnedMaxExtent
///   final target = (np.pixels + delta).clamp(0.0, np.maxScrollExtent);
///
/// If `delta` were the true growth, `pixels + delta` could never exceed the new
/// maxScrollExtent, so the clamp could never fire. It fires only when `ref` is
/// STALE: `target > max` is equivalent to `pixels > ref`, i.e. the baseline was
/// recorded when the extent was smaller than where the reader now is. The result
/// of the clamp is offset == maxScrollExtent, which in this REVERSED list is the
/// OLDEST message: the beginning of the conversation.
///
/// The baseline goes stale whenever the hold SKIPS a notification while the
/// extent grows. One path that skips is deliberate: a transcript-epoch change
/// re-baselines and returns without compensating (the fix for a parked reader
/// being flung by a rehydrate). It re-baselines by CLEARING, so the next
/// notification that does run the hold compares against nothing useful.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class R43Gateway extends GatewayClient {
  R43Gateway() : super(_cfg);
  final responses = <String, Map<String, dynamic>>{};
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final _stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);

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
      'session.create' => {'session_id': 'live-r43'},
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'prompt.submit' => {'status': 'streaming'},
      'session.active_list' => {
          'sessions': [
            {'session_id': 'live-r43', 'status': 'working'}
          ]
        },
      'session.usage' => {'context_used': 1000, 'context_max': 128000},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data,
          {String sid = 'live-r43'}) =>
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

List<Map<String, dynamic>> _history({int extra = 0, int initial = 14}) {
  String body(String tag, int i) =>
      '$tag $i\n${List.generate(6, (j) => '$tag-$i line $j').join('\n')}';
  final rows = <Map<String, dynamic>>[];
  var ts = 1.0;
  for (var i = 0; i < initial; i++) {
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

Future<(R43Gateway, ChatStore)> _open(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1260, 2700);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final gw = R43Gateway();
  gw.responses['session.resume'] = {
    'session_id': 'live-r43',
    'resumed': 'stored-r43',
    // SHORT to start with: the baseline gets armed at this extent, and the test
    // is about the reader scrolling past it as the turn grows the transcript.
    'messages': _history(initial: 3),
  };
  final store = ChatStore(config: _cfg, client: gw);
  addTearDown(store.dispose);
  await store.connect();
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
  await tester.pump();
  await store.resumeSession('stored-r43');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
  return (gw, store);
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 80));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a parked reader is never teleported to the beginning',
      (tester) async {
    final (gw, store) = await _open(tester);
    final startExtent = _pos(tester).maxScrollExtent;
    expect(startExtent, lessThan(3000),
        reason: 'this test needs a SHORT transcript to start with, so the '
            'baseline gets armed at a small extent: $startExtent');

    // The reader starts scrolling up WHILE the turn grows the transcript under
    // them. This is the reported situation: "a response is streaming in, if you
    // are browsing the conversation in the middle somewhere". The baseline is
    // armed at the extent the drag starts at and nothing refreshes it during the
    // gesture, so the content that arrives now is invisible to the hold.
    final gesture = await tester.startGesture(
        tester.getTopLeft(find.byType(ListView).first) + const Offset(10, 6));
    var grown = 0;
    for (var step = 0; step < 60; step++) {
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump(const Duration(milliseconds: 16));
      if (step % 6 == 5) {
        // The reply keeps arriving mid-scroll. Text deltas are DEFERRED while
        // the reader is away, so they accumulate in the model and paint at the
        // next structural event, which is what makes the extent jump by a lot in
        // one step rather than a pixel at a time.
        gw.emit('message.delta', {
          'text': List.generate(12, (j) => 'streamed line $step-$j of the reply')
              .join('\n'),
        });
        gw.emit('message.start', {});
        gw.emit('tool.start', {
          'name': 'terminal',
          'tool_id': 'g$step',
          'context': 'step $step command',
        });
        await tester.pump(const Duration(milliseconds: 16));
        grown++;
      }
    }
    await gesture.up();
    // Fixed pumps, not pumpAndSettle: the running turn keeps a spinner
    // animating, so pumpAndSettle never settles.
    await _settle(tester);
    await _settle(tester);
    final parked = _pos(tester).pixels;
    final extentNow = _pos(tester).maxScrollExtent;
    // ignore: avoid_print
    print('PARKED pixels=${parked.toStringAsFixed(0)} '
        'extentNow=${extentNow.toStringAsFixed(0)} '
        'startExtent=${startExtent.toStringAsFixed(0)} growths=$grown');
    expect(parked, greaterThan(startExtent),
        reason: 'the reader must have scrolled PAST the extent the baseline was '
            'armed at, which is what makes the baseline stale: '
            'pixels=$parked ref<=$startExtent');
    // And they are NOT at the top: the point is that something throws them
    // there, not that they scrolled there.
    expect(extentNow - parked, greaterThan(500),
        reason: 'the reader must have room above them for the jump to be the '
            'anomaly under test: pixels=$parked max=$extentNow');

    // The next structural change is where the hold runs again. On the device
    // this is the moment a thinking trace starts.
    gw.emit('message.start', {});
    await _settle(tester);
    await _settle(tester);

    final after = _pos(tester);
    final atTop = after.pixels >= after.maxScrollExtent - 1;
    expect(atTop, isFalse,
        reason: 'the reader was thrown to the beginning of the conversation: '
            'pixels=${after.pixels} max=${after.maxScrollExtent} '
            '(parked at $parked)');
    expect((after.pixels - parked).abs(), lessThan(600),
        reason: 'the reader should still be near where they were reading');
  });
}
