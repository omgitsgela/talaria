import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 20 (2026-09-14): after COLLAPSING a thinking trace, the view is forced
/// back to the bottom (the shrunken content no longer overflows the viewport,
/// so `pixels` clamps to 0) — but the "jump to latest" arrow stayed on screen.
///
/// Root cause: the arrow's visibility (`_showJumpArrow`) is only ever
/// recomputed from SCROLL notifications (`_onScroll` → `_updateArrow`), and a
/// content-size change produces `ScrollMetricsNotification`, not a scroll —
/// so a reader who collapses a trace at the bottom keeps a stale arrow.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class R20Gateway extends GatewayClient {
  R20Gateway() : super(_cfg);
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
    switch (method) {
      case 'session.resume':
        // A SHORT conversation (the reported "new conversation" shape) whose
        // only long content is the trace: collapsed it fits the viewport,
        // expanded it overflows by just enough to scroll.
        return {
          'session_id': 'live-b',
          'resumed': params['session_id'],
          'messages': [
            {'role': 'user', 'text': 'Trace question?', 'ts': 1.0},
            {
              'role': 'assistant',
              'text': 'Short answer.',
              'reasoning': List.generate(
                      12,
                      (i) => 'Reasoning paragraph $i, long enough to take a line.')
                  .join('\n\n'),
              'ts': 2.0,
            },
          ],
          'info': {'model': 'test-model'},
        };
      case 'session.list':
        return {'sessions': const <Map<String, dynamic>>[]};
      default:
        return {};
    }
  }

  @override
  Future<void> dispose() async {
    await pushed.close();
    await _stateCtl.close();
  }
}

ScrollPosition _transcript(WidgetTester tester) {
  final states = tester.stateList<ScrollableState>(
      find.byType(Scrollable, skipOffstage: false));
  for (final st in states) {
    if (st.context.findAncestorWidgetOfExactType<ListView>() != null) {
      return st.position;
    }
  }
  return states.first.position;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'collapsing a trace at the bottom hides the jump-to-latest arrow',
      (tester) async {
    tester.view.physicalSize = const Size(1260, 2700);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final gw = R20Gateway();
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: HomeScreen(storeOverride: store))));
    await tester.pump();
    await store.resumeSession('stored-b');
    await tester.pumpAndSettle();

    final pos = _transcript(tester);

    // Collapsed trace: the conversation fits the viewport.
    expect(pos.maxScrollExtent, 0,
        reason: 'the collapsed trace fits, so there is nothing to scroll');

    // The user taps the trace to read it.
    expect(find.text('Reasoning'), findsOneWidget,
        reason: 'a finished turn shows its (collapsed) reasoning tile');
    await tester.tap(find.text('Reasoning'));
    await tester.pumpAndSettle();
    final expandedMax = pos.maxScrollExtent;
    expect(expandedMax, greaterThan(48),
        reason: 'the expanded trace makes the conversation scrollable');

    // Reading it means being away from the newest end: the arrow appears.
    pos.jumpTo(expandedMax);
    await tester.pump();
    expect(pos.pixels, greaterThan(48),
        reason: 'the reader is away from the newest end');
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget,
        reason: 'a scrolled-up reader gets the jump-to-latest arrow');

    // Collapse it again — the header is still on screen, so the tap lands.
    expect(find.text('Reasoning'), findsOneWidget);
    await tester.tap(find.text('Reasoning'));
    await tester.pumpAndSettle();

    expect(pos.maxScrollExtent, 0,
        reason: 'the collapsed conversation fits the viewport again');
    expect(pos.pixels, 0,
        reason: 'the shrunken content clamps the view to the newest end');
    expect(find.byIcon(Icons.arrow_downward), findsNothing,
        reason: 'at the bottom the arrow must not be visible: a content-size '
            'change has to resync this state, not just scroll events');
  });
}
