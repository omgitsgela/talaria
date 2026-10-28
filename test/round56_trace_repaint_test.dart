import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/store/chat_store.dart';
import 'package:talaria/src/widgets/message_bubble.dart';

/// Issue #8: hiding or showing reasoning traces did not repaint the
/// transcript. `_applyReasoningDisplay()` blanked `effectiveReasoning`
/// without bumping `revision`, and `MessageBubble` is memoized against
/// `revision`, so the row kept its cached subtree and the trace tiles stayed
/// on screen until some unrelated content change landed. The issue's own
/// evidence was maxScrollExtent staying fixed after the toggle.
///
/// Widget-level proof: with the fix, hiding a trace removes the 'Reasoning'
/// tile immediately; toggling back restores it; and the revision bump is
/// conditional so rows that were already correct do not rebuild (the
/// streaming memoization win must survive the toggle).
final _cfg = GatewayConfig(url: 'http://localhost:1');

class T8Gateway extends GatewayClient {
  T8Gateway() : super(_cfg);
  final _events = StreamController<GatewayEvent>.broadcast(sync: true);

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => _events.stream;
  @override
  Stream<GwConnectionState> get stateChanges => const Stream.empty();
  @override
  Stream<ServerRequest> get serverRequests => const Stream.empty();
  @override
  Future<void> connect({bool isReconnect = false}) async {}

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    return switch (method) {
      'session.resume' => {
          'session_id': 'live-t',
          'resumed': params['session_id'],
        },
      'session.create' => {'session_id': 'live-t'},
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      // The live row must be present: the reconcile treats a session it
      // cannot find as DEAD (transcript cleared, loading spinner up), which
      // would exercise the wrong path and hang pumpAndSettle on the spinner.
      'session.active_list' => {
          'sessions': [
            {
              'id': 'live-t',
              'session_id': 'live-t',
              'session_key': 't',
              'status': 'idle',
            },
          ],
        },
      'config.set' => {'key': params['key'], 'value': params['value']},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data, {String sid = 'live-t'}) =>
      _events.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(MessageBubble.resetTestBuildCounts);

  testWidgets('hiding reasoning repaints the transcript (#8)', (tester) async {
    final gw = T8Gateway();
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('t');

    // The gateway's event stream here is a SYNC broadcast controller, so the
    // emits land in the store immediately. Do NOT await Future.delayed inside
    // testWidgets: the widget-test zone's fake clock only advances on pump,
    // so awaiting a zero-delay timer there deadlocks.
    gw.emit('message.start', {});
    gw.emit('thinking.delta', {'text': 'a deep trace'});
    gw.emit('message.complete', {'text': 'the answer'});

    final m = store.messages.last;
    expect(m.reasoning, 'a deep trace');
    expect(m.effectiveReasoning, 'a deep trace');
    final r0 = m.revision;

    // Pump the transcript rows (not the whole HomeScreen): the contract under
    // test is the row memo, and it must repaint when the display toggle lands.
    Future<void> pumpTranscript() async {
      await tester.pumpWidget(MaterialApp(
        home: ListView(
          children: [
            for (final msg in store.messages)
              MessageBubble(message: msg.copy(), isUser: msg.role == 'user'),
          ],
        ),
      ));
    }

    await pumpTranscript();
    await tester.pump();
    expect(find.text('Reasoning'), findsOneWidget,
        reason: 'the trace tile is on screen before the toggle');

    // The reported reproduction: toggle OFF on a loaded conversation.
    await store.setReasoningDisplay(false);
    expect(m.effectiveReasoning, isEmpty);
    expect(m.revision, greaterThan(r0),
        reason: 'the display-only change must move revision, the exact signal '
            'the bubble memo watches; without it the cached subtree is '
            'returned and the tile stays put - the reported bug');
    await pumpTranscript();
    await tester.pump();
    expect(find.text('Reasoning'), findsNothing);
    expect(find.text('the answer'), findsOneWidget);

    // Toggle back: the same repaint restores it (hiding is display-only).
    await store.setReasoningDisplay(true);
    await pumpTranscript();
    await tester.pump();
    expect(find.text('Reasoning'), findsOneWidget);
  });

  test('the display setter bumps revision only when the value changes', () {
    final m = ChatMessage(role: 'assistant', text: 'answer', reasoning: 'trace');
    final r0 = m.revision;
    m.effectiveReasoning = ''; // hide: a real change
    expect(m.revision, r0 + 1);
    expect(m.contentRevision, r0,
        reason: 'display-only: the content revision must not move');
    m.effectiveReasoning = ''; // already hidden: no change, no bump
    expect(m.revision, r0 + 1,
        reason: 'rows whose value was already correct must NOT bump - '
            'bumping everything would rebuild the whole transcript on every '
            'store notification and undo the streaming memoization win');
    m.effectiveReasoning = 'trace'; // re-show: a real change again
    expect(m.revision, r0 + 2);
  });

  testWidgets('a memoized row rebuilds on the toggle but not on a no-op pump',
      (tester) async {
    final m = ChatMessage(role: 'assistant', text: 'answer', reasoning: 'deep trace');
    await tester.pumpWidget(
        MaterialApp(home: MessageBubble(message: m.copy(), isUser: false)));
    expect(find.text('Reasoning'), findsOneWidget);
    expect(MessageBubble.buildCountFor(m), 1);

    // Hide via the display view: the memo must notice the revision bump.
    m.effectiveReasoning = '';
    await tester.pumpWidget(
        MaterialApp(home: MessageBubble(message: m.copy(), isUser: false)));
    expect(MessageBubble.buildCountFor(m), 2,
        reason: 'without the bump the cached subtree is returned with the '
            'trace tile still laid out (issue #8)');

    // Nothing changed: the memo must NOT rebuild again.
    await tester.pumpWidget(
        MaterialApp(home: MessageBubble(message: m.copy(), isUser: false)));
    expect(MessageBubble.buildCountFor(m), 2,
        reason: 'the toggle fix must not turn every notification into a rebuild');
  });
}
