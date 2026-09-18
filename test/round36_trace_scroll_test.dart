import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Issue #1, second attempt. The round-34 test only covered a MONOTONICALLY
/// growing trace, which the read-hold handles correctly. The real failure is a
/// mid-stream extent SHRINK:
///
///   reading (scrolled up)   pixels=330.0   max=4468.3
///   trace collapses         pixels=330.0   max=1094.3   <- extent drops 3374
///   next streamed character pixels=0.0     max=1094.3   <- dragged to bottom
///   every character after   pixels=0.0                 <- pinned there
///
/// The hold applies the negative delta, `clamp(0, max)` lands it on offset 0,
/// and `_onScroll` then re-arms the follow FROM that clamped offset, so every
/// later character keeps the view at the newest message. The trace row is an
/// `ExpansionTile` whose height changes as it animates or reflows, so a shrink
/// mid-stream is a normal occurrence, not an edge case.

final _cfg = GatewayConfig(url: 'http://localhost:1');

class R36Gateway extends GatewayClient {
  R36Gateway() : super(_cfg);
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

ScrollPosition _pos(WidgetTester tester) {
  for (final s in tester.stateList<ScrollableState>(
      find.byType(Scrollable, skipOffstage: false))) {
    if (s.position.maxScrollExtent > 100) return s.position;
  }
  throw StateError('no scrollable transcript');
}

Future<(R36Gateway, ChatStore)> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1260, 2700);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final gw = R36Gateway();
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
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
  return (gw, store);
}

/// A streaming turn with a long trace, then the reader scrolls well up.
Future<void> _streamAndScrollUp(
    WidgetTester tester, R36Gateway gw, ScrollPosition p) async {
  gw.emit('message.start', {'message_id': 'm1'});
  await tester.pump(const Duration(milliseconds: 16));
  for (var i = 0; i < 25; i++) {
    gw.emit('reasoning.delta',
        {'text': 'a fairly long reasoning sentence number $i. '});
    await tester.pump(const Duration(milliseconds: 16));
  }
  final g =
      await tester.startGesture(tester.getCenter(find.byType(ListView).first));
  for (var i = 0; i < 12; i++) {
    await g.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('issue #1: a mid-stream extent shrink must not pin the reader', () {
    testWidgets('collapsing the trace mid-stream keeps the reader in place',
        (tester) async {
      final (gw, _) = await _open(tester);
      final p = _pos(tester);
      await _streamAndScrollUp(tester, gw, p);

      final anchor = p.pixels;
      expect(anchor, greaterThan(100),
          reason: 'the reader must be scrolled away from the newest end');

      // The trace collapses (its ExpansionTile header tapped, or any reflow).
      final header = find.text('Thinking…');
      expect(header, findsOneWidget);
      await tester.tap(header.first, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Characters keep arriving after the shrink.
      for (var i = 0; i < 6; i++) {
        gw.emit('reasoning.delta', {'text': 'more after the shrink $i. '});
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(p.pixels, greaterThan(48),
          reason: 'a mid-stream extent SHRINK must not drag the reader back to '
              'the newest end; that is the reported "it keeps forcing the '
              'window to the bottom for every character"');
    });

    testWidgets('the reader is not pinned by a shrink-and-grow sequence',
        (tester) async {
      final (gw, _) = await _open(tester);
      final p = _pos(tester);
      await _streamAndScrollUp(tester, gw, p);
      final anchor = p.pixels;

      // Shrink, then grow again repeatedly while characters stream: the
      // sequence that walked the offset down to 0 in the diagnostic.
      for (var round = 0; round < 3; round++) {
        final header = find.text('Thinking…');
        if (header.evaluate().isNotEmpty) {
          await tester.tap(header.first, warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 200));
        }
        for (var i = 0; i < 4; i++) {
          gw.emit('reasoning.delta', {'text': 'grow $round.$i. '});
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      expect(p.pixels, greaterThan(48),
          reason: 'repeated shrinks must not walk the offset down to the '
              'newest end (anchor was $anchor)');
    });

    testWidgets('following still works: at the bottom, characters keep it there',
        (tester) async {
      final (gw, _) = await _open(tester);
      final p = _pos(tester);

      // A fresh open leaves the reader at the newest end, where following is
      // the correct behaviour and must NOT have been disabled by the fix.
      expect(p.pixels, 0);
      gw.emit('message.start', {'message_id': 'm1'});
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 8; i++) {
        gw.emit('reasoning.delta', {'text': 'trace $i. '});
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(p.pixels, lessThan(1),
          reason: 'a reader sitting at the newest end still follows');
    });

    testWidgets('scrolling back to the bottom re-arms following',
        (tester) async {
      final (gw, _) = await _open(tester);
      final p = _pos(tester);
      await _streamAndScrollUp(tester, gw, p);
      expect(p.pixels, greaterThan(100));

      // Drag back down to the newest end and let go.
      final g =
          await tester.startGesture(tester.getCenter(find.byType(ListView).first));
      for (var i = 0; i < 20; i++) {
        await g.moveBy(const Offset(0, -40));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(p.pixels, lessThan(1), reason: 'the drag returned to the bottom');

      // Now following must resume.
      for (var i = 0; i < 5; i++) {
        gw.emit('reasoning.delta', {'text': 'after returning $i. '});
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(p.pixels, lessThan(1),
          reason: 'returning to the newest end must re-arm following');
    });
  });
}
