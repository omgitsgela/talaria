import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';
import 'package:talaria/src/widgets/message_bubble.dart';

/// Round 21 (2026-09-14): the streaming hot path must not rebuild what did
/// not change.
///
/// The store notifies on EVERY streamed delta, and the transcript's list
/// builder then re-runs for every visible row on every notify. Before this
/// round each of those rebuilds re-ran the bubble's FULL build — re-parsing
/// its markdown, rebuilding the SelectableText machinery, re-deriving text/
/// tools from the parts list — even though a delta only changes the ONE
/// message that owns the streaming tail.
///
/// Fix: [ChatMessage] carries a content `revision` (bumped by every content
/// mutation); the transcript builder passes each row a SNAPSHOT of its
/// message (frozen revision), and `MessageBubble` memoizes its built subtree
/// against revision + theme + markdown pref — a notify that did not change
/// this message renders the cached subtree, not a re-parse.
///
/// Measured cost that REMAINS by design (documented, not a regression):
/// when the list's item COUNT changes (a new message row is prepended at the
/// newest end of the reversed list), every VISIBLE row's child slot index
/// moves and the framework re-inflates the visible states once (the delegate
/// has no findChildIndexCallback). One re-inflation per count change — the
/// price of `addAutomaticKeepAlives: false` (Round 19, which fixed the
/// device-only element-tree asserts). Between count changes, steady
/// streaming touches only the owner row.
final _cfg = GatewayConfig(url: 'http://localhost:1');

void main() {
  group('ChatMessage content revision', () {
    test('part mutations bump the content revision; reads do not', () {
      final m = ChatMessage(role: 'assistant', pending: true);
      final r0 = m.contentRevision;
      expect(m.revision, r0);

      m.appendText('hello');
      expect(m.contentRevision, r0 + 1);

      m.appendReasoning('thinking');
      expect(m.contentRevision, r0 + 2);
      expect(m.text, 'hello');
      expect(m.reasoning, 'thinking');

      // Derived reads must not mutate anything.
      final r1 = m.contentRevision;
      m.text;
      m.reasoning;
      m.tools;
      m.lastTool;
      expect(m.contentRevision, r1,
          reason: 'derived reads must not mutate state');
    });

    test('derived bucket getters stay exact as parts interleave', () {
      final m = ChatMessage(role: 'assistant', pending: true);
      m.appendReasoning('think 1 ');
      m.appendText('a ');
      m.addTool(ToolActivity(name: 'read_file'));
      m.appendReasoning('think 2');
      m.appendText('b');
      expect(m.text, 'a b', reason: 'prose parts join in order');
      expect(m.reasoning, 'think 1 think 2');
      expect(m.tools.map((t) => t.name).toList(), ['read_file']);
      expect(m.lastTool?.name, 'read_file');
    });

    test('pending/error are visible state: they bump revision, not content',
        () {
      final m = ChatMessage(role: 'assistant', pending: true);
      final r = m.contentRevision;
      m.pending = false;
      expect(m.revision, greaterThan(r));
      expect(m.contentRevision, r,
          reason: 'pending is display state, not content');
    });
  });

  group('MessageBubble row memoization', () {
    testWidgets('steady streaming rebuilds only the owner row', (tester) async {
      MessageBubble.resetTestBuildCounts();
      final gw = _R21Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();
      await store.resumeSession('r21-a');
      await tester.pumpAndSettle();

      // The resume seeded: user, assistant, user, assistant.
      final assistants =
          store.messages.where((m) => m.role == 'assistant').toList();
      expect(assistants, hasLength(2));
      final first = assistants[0];
      final second = assistants[1];
      expect(MessageBubble.buildCountFor(first), 1,
          reason: 'each visible row builds once when it inflates');
      expect(MessageBubble.buildCountFor(second), 1);

      // A new turn starts: a FRESH tail row is prepended (count 4 -> 5), which
      // moves every visible child slot in the reversed list. The rows keep their
      // IDENTITY across that shift - the row key sits on the widget the builder
      // RETURNS, and `findChildIndexCallback` tells the sliver where that row
      // moved to - so the existing rows are re-used and their memo holds. No
      // re-inflation, and no State loss: a trace the reader had expanded used to
      // collapse right here.
      gw.push(GatewayEvent(type: 'message.start', sessionId: 'live-r21'));
      await tester.pump();
      final tail = store.messages.last;
      expect(tail, isNot(same(first)));
      expect(MessageBubble.buildCountFor(tail), 1);
      expect(MessageBubble.buildCountFor(first), 1,
          reason: 'a count change must NOT re-inflate a row that kept its '
              'identity');
      expect(MessageBubble.buildCountFor(second), 1);

      // Now STEADY streaming: two deltas into the tail, count unchanged.
      // The owner row rebuilds once per delta; the OTHER rows must not
      // rebuild at all (memo hit + widget == skip).
      gw.push(GatewayEvent(type: 'message.delta', sessionId: 'live-r21',
          payload: {'text': 'streaming answer ' * 4}));
      await tester.pump();
      expect(tail.text, isNotEmpty);
      expect(MessageBubble.buildCountFor(tail), 2,
          reason: 'the owner row rebuilds once per delta');
      expect(MessageBubble.buildCountFor(first), 1,
          reason: 'an untouched row must not rebuild on a foreign delta');
      expect(MessageBubble.buildCountFor(second), 1,
          reason: 'an untouched row must not rebuild on a foreign delta');

      gw.push(GatewayEvent(type: 'message.delta', sessionId: 'live-r21',
          payload: const {'text': ' more'}));
      await tester.pump();
      await tester.pump(); // a second pump must not add phantom builds
      expect(MessageBubble.buildCountFor(tail), 3);
      expect(MessageBubble.buildCountFor(first), 1);
      expect(MessageBubble.buildCountFor(second), 1);
    });

    testWidgets('the streamed tail is still rendered live', (tester) async {
      final gw = _R21Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();
      await store.resumeSession('r21-a');
      await tester.pumpAndSettle();

      gw.push(GatewayEvent(type: 'message.start', sessionId: 'live-r21'));
      await tester.pump();
      gw.push(GatewayEvent(type: 'message.delta', sessionId: 'live-r21',
          payload: const {'text': 'visible streamed text'}));
      await tester.pump();
      expect(find.textContaining('visible streamed text'), findsOneWidget,
          reason: 'the memo must not serve stale content for the live row');
    });
  });

  group('store hygiene (Round 21)', () {
    test('identical roster pulls do not re-notify listeners', () async {
      final gw = _R21Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      gw.roster = [
        {'id': 's1', 'title': 'A', 'preview': 'p1', 'started_at': 100.0},
        {'id': 's2', 'title': 'B', 'preview': 'p2', 'started_at': 200.0},
      ];
      await store.connect();
      // connect() already pulled the roster once (same rows) — the explicit
      // pull below is the no-op case; the FIRST observable load happens via
      // a change.
      var notifies = 0;
      store.addListener(() => notifies++);
      await store.loadSessions();
      expect(notifies, 0,
          reason: 'an unchanged roster must not notify listeners');

      // A real change still notifies.
      gw.roster = [
        {
          'id': 's1',
          'title': 'A',
          'preview': 'p1-changed',
          'started_at': 100.0
        },
        {'id': 's2', 'title': 'B', 'preview': 'p2', 'started_at': 200.0},
      ];
      notifies = 0;
      await store.loadSessions();
      expect(notifies, greaterThan(0),
          reason: 'a genuine roster change still notifies');
      expect(store.sessions.first.preview, 'p1-changed');
    });

    test('hidden traces stay hidden on resume rehydrate', () async {
      final gw = _R21Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      gw.roster = const [];
      await store.connect();
      // Hide traces BEFORE resuming (the round-8 display switch).
      await store.setReasoningDisplay(false);

      await store.resumeSession('r21-trace');
      await Future<void>.delayed(Duration.zero);

      final withTrace =
          store.messages.where((m) => m.reasoning.isNotEmpty).toList();
      expect(withTrace, isNotEmpty, reason: 'the gateway row carried a trace');
      for (final m in withTrace) {
        expect(m.reasoning.isNotEmpty, isTrue,
            reason: 'the RAW trace survives hide (re-show restores it)');
        expect(m.effectiveReasoning, isEmpty,
            reason: 'a hidden trace must not be resurrected on rehydrate');
      }
    });
  });
}

/// Gateway fake for this round: a two-turn conversation whose second turn
/// carries a trace (the rehydrate case), plus live event push.
class _R21Gateway extends GatewayClient {
  _R21Gateway() : super(_cfg);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final _stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);
  List<Map<String, dynamic>> roster = const [];

  void push(GatewayEvent ev) => pushed.add(ev);

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
        return {
          'session_id': 'live-r21',
          'resumed': params['session_id'],
          'messages': [
            {'role': 'user', 'text': 'first question', 'ts': 10.0},
            {
              'role': 'assistant',
              'text': 'First answer with **markdown**.',
              'ts': 11.0,
            },
            {'role': 'user', 'text': 'second question', 'ts': 12.0},
            {
              'role': 'assistant',
              'text': 'Second answer.',
              'reasoning': 'The trace text. ' * 20,
              'ts': 13.0,
            },
          ],
          'info': {'model': 'test-model'},
        };
      case 'session.list':
        return {'sessions': roster};
      case 'config.get':
        if (params['key'] == 'reasoning') {
          return {'value': 'medium', 'display': 'hide'};
        }
        return {};
      case 'config.set':
        return {'key': params['key'], 'value': params['value']};
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
