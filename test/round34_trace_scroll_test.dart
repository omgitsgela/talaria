import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Issue #1: "When a thinking trace is writing out, the conversation window is
/// pinned at the bottom and the user ends up fighting against it when they
/// scroll up."
///
/// Build 32 made the follow-to-bottom yield to a live gesture while a MESSAGE
/// streams (round 33: interleaved finger steps + `message.delta`). This file
/// re-runs that exact reproduction against the REASONING stream
/// (`reasoning.delta`), which appends to the in-flight assistant message's
/// reasoning part instead of its text. If the gesture guard is shared, this
/// passes; if the trace path has its own re-pin, it fails with the offset
/// reset to 0.

final _cfg = GatewayConfig(url: 'http://localhost:1');

class R34Gateway extends GatewayClient {
  R34Gateway() : super(_cfg);
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
      'session.create' => {'session_id': 'live-a'},
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'prompt.submit' => {'status': 'streaming'},
      'session.usage' => {'context_used': 1000, 'context_max': 128000},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data, {String sid = 'live-b'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
    await _stateCtl.close();
  }
}

/// The transcript's scroll position: the Scrollable with a large extent.
ScrollPosition _transcriptPosition(WidgetTester tester) {
  for (final s in tester.stateList<ScrollableState>(
      find.byType(Scrollable, skipOffstage: false))) {
    if (s.position.maxScrollExtent > 100) return s.position;
  }
  throw StateError('no scrollable transcript found');
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 60));
}

Future<(R34Gateway, ChatStore)> _openLongConversation(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1260, 2700);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final gw = R34Gateway();
  gw.responses['session.resume'] = {
    'session_id': 'live-b',
    'resumed': 'stored-b',
    'messages': List.generate(
        30, (i) => {'role': 'user', 'text': 'line $i', 'ts': i.toDouble()})
  };
  final store = ChatStore(config: _cfg, client: gw);
  addTearDown(store.dispose);
  await store.connect();
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
  await tester.pump();
  await store.resumeSession('stored-b');
  await _settle(tester);
  return (gw, store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reasoning-trace streaming must not fight the reader (#1)', () {
    testWidgets('a live drag survives a reasoning trace streaming in',
        (tester) async {
      final (gw, _) = await _openLongConversation(tester);
      final pos = _transcriptPosition(tester);

      // The exact round-33 reproduction: 30 small finger steps, a streamed
      // delta between each. A single big moveBy would teleport past the
      // near-bottom band and prove nothing.
      final gesture =
          await tester.startGesture(tester.getCenter(find.byType(ListView).first));
      for (var i = 0; i < 30; i++) {
        await gesture.moveBy(const Offset(0, 14));
        // A real turn: message.start once, then the reasoning trace grows.
        if (i == 0) {
          gw.emit('message.start', {'message_id': 'm1'});
        }
        gw.emit('reasoning.delta', {'text': 'thinking chunk $i '});
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(pos.pixels, greaterThan(48),
          reason: 'the drag must be able to escape the near-bottom band while '
              'a reasoning trace is streaming in');

      await gesture.up();
      await _settle(tester);

      expect(pos.pixels, greaterThan(48),
          reason: 'releasing must hand the position to the read-hold, not the '
              'follow, while the trace continues to grow');
    });

    testWidgets('the reader keeps their anchor as the trace grows',
        (tester) async {
      final (gw, _) = await _openLongConversation(tester);
      final pos = _transcriptPosition(tester);

      final gesture =
          await tester.startGesture(tester.getCenter(find.byType(ListView).first));
      await gesture.moveBy(const Offset(0, 260));
      await tester.pump();
      await gesture.up();
      await _settle(tester);

      final anchor = pos.pixels;
      expect(anchor, greaterThan(0));

      for (var i = 0; i < 12; i++) {
        gw.emit('reasoning.delta', {'text': 'more reasoning $i '});
        await tester.pump(const Duration(milliseconds: 16));
      }

      // The read-hold shifts the offset by the extent delta, so the offset is
      // allowed to grow; what must not happen is a collapse back to the newest
      // end.
      expect(pos.pixels, greaterThan(anchor - 1),
          reason: 'the reading position must be held, never reset to the bottom');
    });
  });
}
