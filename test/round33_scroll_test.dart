import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Reported: "when a response is streaming in during a conversation, the
/// conversation gets forced to the bottom after every character. We should allow
/// the user to scroll up and let the responses flow in below."
///
/// The read-hold (round 15) only engages once `_stickToBottom` is false, and
/// round 15's test reached that state with a PROGRAMMATIC `jumpTo(300)`. A real
/// finger is different: `userScrollDirection` is non-idle for the whole drag, and
/// the follow path used to jump to the newest end regardless, cancelling the drag
/// before it could move far enough to disarm the follow. So these tests drive a
/// live gesture and stream into it, which is the shape the bug actually needs.

final _cfg = GatewayConfig(url: 'http://localhost:1');

class R33Gateway extends GatewayClient {
  R33Gateway() : super(_cfg);
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

Future<(R33Gateway, ChatStore)> _openLongConversation(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1260, 2700);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final gw = R33Gateway();
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

  group('streaming must not fight the reader (round 33)', () {
    testWidgets('a live drag survives characters streaming in',
        (tester) async {
      final (gw, _) = await _openLongConversation(tester);
      final pos = _transcriptPosition(tester);

      // A real finger does not teleport: it moves in small steps, and a streamed
      // reply delivers a store change BETWEEN those steps. Each one jumps to the
      // newest end, so if the follow does not yield to the gesture the offset is
      // reset before it can ever accumulate past the near-bottom band. That is
      // the trap, so the test has to interleave them.
      final gesture =
          await tester.startGesture(tester.getCenter(find.byType(ListView).first));
      for (var i = 0; i < 30; i++) {
        await gesture.moveBy(const Offset(0, 14));
        gw.emit('message.delta', {'text': 'chunk $i '});
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(pos.pixels, greaterThan(48),
          reason: 'the drag must be able to escape the near-bottom band while '
              'characters are streaming in');

      await gesture.up();
      await _settle(tester);

      // And once the finger is gone the view stays where they left it, with the
      // reply continuing to grow below.
      expect(pos.pixels, greaterThan(48),
          reason: 'releasing should hand the position to the read-hold, not the '
              'follow');
    });

    testWidgets('the reader keeps their anchor as the reply grows',
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
        gw.emit('message.delta', {'text': 'more text $i '});
        await tester.pump(const Duration(milliseconds: 16));
      }

      // The read-hold shifts the offset by the extent delta, so the offset is
      // allowed to grow; what must not happen is a collapse back to the newest
      // end, which is what dragging the reader to the bottom looks like.
      expect(pos.pixels, greaterThan(anchor - 1),
          reason: 'the reading position must be held, never reset to the bottom');
    });
  });
}
