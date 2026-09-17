import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 15 (2026-09-13): while a reply is streaming, the user's reading
/// position must not drift.
///
/// Geometry: the transcript is a REVERSED list (offset 0 = newest/bottom).
/// With NO compensation, when the newest message grows (streaming text
/// appended at offset 0), maxScrollExtent grows while the offset is frozen,
/// so the content under the viewport slides toward the newest end — the text
/// the user is reading drifts up out from under them ("keeps shifting as if
/// it's relative"). The view holds the reading position by shifting the
/// offset by the extent delta on each content change while the user is away
/// from the bottom (and only when not actively scrolling).
///
/// NOTE on the test harness: a streaming turn keeps a spinner animating, so
/// `pumpAndSettle` can hang; these tests use fixed pumps (pump + pump(60ms))
/// which is what the DIAG harness used to measure the real drift.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class R15Gateway extends GatewayClient {
  R15Gateway() : super(_cfg);
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

/// The transcript's scroll position: the Scrollable with a large extent
/// (the transcript), not the small fixed-height composer input.
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

Future<ChatStore> _openLongSession(R15Gateway gw) async {
  gw.responses['session.resume'] = {
    'session_id': 'live-b',
    'resumed': 'stored-b',
    'messages': List.generate(
        30, (i) => {'role': 'user', 'text': 'line $i', 'ts': i.toDouble()})
  };
  final store = ChatStore(config: _cfg, client: gw);
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reading position is stable while streaming (round 15)', () {
    testWidgets('the anchor message stays put while the reply grows beneath',
        (tester) async {
      tester.view.physicalSize = const Size(1260, 2700);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final gw = R15Gateway();
      final store = await _openLongSession(gw);
      addTearDown(store.dispose);
      await store.connect();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();
      await store.resumeSession('stored-b');
      await _settle(tester);

      // The user scrolls up to READ history (away from the newest end).
      final pos = _transcriptPosition(tester);
      pos.jumpTo(300);
      await _settle(tester);

      expect(find.text('line 20'), findsOneWidget,
          reason: 'the anchor is in the viewport before the turn starts');
      final anchorBefore = tester.getTopLeft(find.text('line 20'));

      // A turn starts and the reply streams in (the newest end keeps growing).
      gw.emit('message.start', {});
      await _settle(tester);
      for (var k = 1; k <= 6; k++) {
        gw.emit('message.delta',
            {'text': 'This is a streamed reply segment $k that wraps lines. '});
        await _settle(tester);
      }

      // The anchor must STILL be on screen (without the fix it drifts up and
      // off the viewport as the reply grows).
      expect(find.text('line 20'), findsOneWidget,
          reason: 'the reading position must not drift the anchor off-screen '
              'while the reply streams in beneath it');
      final anchorAfter = tester.getTopLeft(find.text('line 20'));
      // Bounded: at most ~one inserted divider line, NOT proportional to the
      // reply height (the old behavior moved with the growing content).
      expect((anchorAfter.dy - anchorBefore.dy).abs(), lessThan(80),
          reason: 'the anchor should hold its position (bounded residual), not '
              'slide by the full grown reply height');
      // And the view is NOT yanked to the bottom.
      expect(pos.pixels, greaterThan(150),
          reason: 'the user is still reading history, not followed to bottom');
    });

    testWidgets('following the bottom still follows (no hold interference)',
        (tester) async {
      tester.view.physicalSize = const Size(1260, 2700);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final gw = R15Gateway();
      final store = await _openLongSession(gw);
      addTearDown(store.dispose);
      await store.connect();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();
      await store.resumeSession('stored-b');
      await _settle(tester);

      // Stay at the bottom (default after open). The turn streams in and the
      // view must KEEP FOLLOWING the newest end.
      gw.emit('message.start', {});
      for (var k = 1; k <= 4; k++) {
        gw.emit('message.delta', {'text': 'Streamed reply $k keeps following. '});
        await _settle(tester);
      }

      final pos = _transcriptPosition(tester);
      expect(pos.pixels, lessThan(48),
          reason: 'at the newest end, streaming must keep the view pinned '
              'to the bottom (offset ~0), not apply the read-hold shift');
    });
  });
}
