import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/models/goal_status.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';
import 'package:talaria/src/theme/markdown_preference.dart';
import 'package:talaria/src/widgets/message_bubble.dart';

/// Round 10 (2026-09-12):
///   1. Rich Markdown in assistant replies + a global settings render toggle.
///   2. A persistent, long-horizon GOAL / status bar in the conversation
///      (mirrors the Hermes desktop's composer goal indicator), read via the
///      read-only `slash.exec {command: 'goal status'}` RPC.
///   Bug A: a new thinking trace no longer causes the transcript to wobble
///   Bug B: a tool call can no longer get stuck in the "running" (gray) state
///      after its segment was sealed by a later `message.interim`.
final _cfg = GatewayConfig(url: 'http://localhost:1');

/// Store-level fake: records calls, serves scripted responses, and lets the
/// test drive connection-state and event streams.
class R10Gateway extends GatewayClient {
  R10Gateway() : super(_cfg);
  final calls = <(String, Map<String, dynamic>)>[];
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
    calls.add((method, params));
    if (responses.containsKey(method)) return responses[method]!;
    return switch (method) {
      'session.create' => {'session_id': 'live-a'},
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'prompt.submit' => {'status': 'streaming'},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data, {String sid = 'live-a'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));
  bool called(String m) => calls.any((c) => c.$1 == m);
  (String, Map<String, dynamic>)? callFor(String m) {
    for (final c in calls.reversed) {
      if (c.$1 == m) return c;
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    await pushed.close();
    await _stateCtl.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── Goal status parser (desktop parity) ─────────────────────────────

  group('parseGoalStatusText', () {
    test('reports no goal', () {
      expect(parseGoalStatusText('No active goal. Set one with /goal <text>.'),
          isA<GoalParseNone>());
      expect(
          parseGoalStatusText('✓ Goal cleared.'), isA<GoalParseNone>());
    });

    test('parses an active goal with its turn meta detail', () {
      final r = parseGoalStatusText(
          '⊙ Goal (active, 3/20 turns): fix the flaky scroll test');
      expect(r, isA<GoalParseValue>());
      final g = (r as GoalParseValue).goal;
      expect(g.status, 'active');
      expect(g.title, 'fix the flaky scroll test');
      expect(g.detail, '3/20 turns');
    });

    test('parses "Goal set" (no meta) as active', () {
      final r =
          parseGoalStatusText('⊙ Goal set (20-turn budget): ship the build');
      expect(r, isA<GoalParseValue>());
      final g = (r as GoalParseValue).goal;
      expect(g.status, 'active');
      expect(g.title, 'ship the build');
    });

    test('parses a paused goal', () {
      final r = parseGoalStatusText(
          '⏸ Goal (paused, 20/20 turns used): ship the build');
      expect(r, isA<GoalParseValue>());
      final g = (r as GoalParseValue).goal;
      expect(g.status, 'paused');
      expect(g.title, 'ship the build');
      expect(g.detail, '20/20 turns used');
    });

    test('parses a done goal', () {
      final r = parseGoalStatusText(
          '✓ Goal done (5/20 turns used): ship the build');
      expect(r, isA<GoalParseValue>());
      final g = (r as GoalParseValue).goal;
      expect(g.status, 'done');
      expect(g.title, 'ship the build');
    });

    test('parses a resumed goal as active', () {
      final r = parseGoalStatusText('▶ Goal resumed: ship the build');
      expect(r, isA<GoalParseValue>());
      final g = switch (r) {
        GoalParseValue(:final goal) => goal,
        _ => throw StateError('expected a goal'),
      };
      expect(g.status, 'active');
      expect(g.title, 'ship the build');
    });

    test('uses only the FIRST non-empty line', () {
      // A real `goal status` may emit extra lines below the status line.
      final r = parseGoalStatusText(
          '⊙ Goal (active, 1/20 turns): first\nsome extra log line');
      expect(r, isA<GoalParseValue>());
      expect((r as GoalParseValue).goal.title, 'first');
    });

    test('unrecognized / empty lines keep the prior state', () {
      expect(parseGoalStatusText(''), isA<GoalParseUnchanged>());
      expect(parseGoalStatusText('random chatter'), isA<GoalParseUnchanged>());
    });
  });

  // ── Goal store refresh (slash.exec 'goal status') ────────────────────

  group('ChatStore goal refresh', () {
    test('refreshGoal reads `goal status` and sets an active goal', () async {
      final gw = R10Gateway();
      gw.responses['slash.exec'] = {
        'output': '⊙ Goal (active, 2/20 turns): write the round-10 tests'
      };
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();

      await store.refreshGoal();

      // The correct read-only RPC must be issued with the canonical command.
      final call = gw.callFor('slash.exec');
      expect(call, isNotNull, reason: 'goal refresh must query the gateway');
      expect(call!.$2['command'], 'goal status');
      expect(call.$2['session_id'], 'live-a');

      expect(store.activeGoal, isNotNull);
      expect(store.activeGoal!.status, 'active');
      expect(store.activeGoal!.title, 'write the round-10 tests');
    });

    test('refreshGoal clears the goal when none is active', () async {
      final gw = R10Gateway();
      // Seed a goal first…
      gw.responses['slash.exec'] = {
        'output': '⊙ Goal (active, 1/20 turns): initial goal'
      };
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.refreshGoal();
      expect(store.activeGoal, isNotNull);

      // …then the gateway reports none.
      gw.responses['slash.exec'] = {
        'output': 'No active goal. Set one with /goal <text>.'
      };
      await store.refreshGoal();
      expect(store.activeGoal, isNull,
          reason: '"No active goal" must clear the bar');
    });

    test('an unrecognized goal output keeps the prior goal (no clobber)',
        () async {
      final gw = R10Gateway();
      gw.responses['slash.exec'] = {
        'output': '⊙ Goal (active, 1/20 turns): keep me'
      };
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.refreshGoal();

      gw.responses['slash.exec'] = {'output': 'totally unrelated text'};
      await store.refreshGoal();
      expect(store.activeGoal, isNotNull);
      expect(store.activeGoal!.title, 'keep me',
          reason: 'an unrecognized line must not wipe a known goal');
    });

    test('clearGoal drops the bar', () async {
      final gw = R10Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      store.clearGoal();
      expect(store.activeGoal, isNull);
    });
  });

  // ── Bug B: late tool.complete must resolve the owning tool ───────────

  group('tool completion resolves across segments', () {
    test('a tool.complete after its segment was sealed no longer sticks',
        () async {
      final gw = R10Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();

      // A tool starts on the active (pending) assistant segment…
      gw.emit('tool.start', {'name': 'terminal', 'tool_id': 'tool-1'});
      // …and its segment is SEALED by a message.interim (pending=false).
      gw.emit('message.interim', {'text': 'thinking about it', 'type': 'final'});

      // Now a LATER segment is appended (the final answer streams in). This is
      // the moment that used to break: `_messages.last` is no longer the
      // segment that owns tool-1.
      gw.emit('message.start', {});

      // A late tool.complete for tool-1 arrives. The old code searched only
      // _messages.last (which has no tools) and left tool-1 stuck in
      // `running`. The fix must find it in its owning (sealed) segment.
      gw.emit('tool.complete', {'name': 'terminal', 'tool_id': 'tool-1',
        'error': null, 'summary': 'ok'});

      await Future<void>.delayed(Duration.zero); // let the sync stream drain

      // Exactly one tool exists, and it is DONE (not stuck running).
      ToolActivity? tool;
      var found = false;
      for (final m in store.messages) {
        for (final t in m.tools) {
          if (t.toolId == 'tool-1') {
            tool = t;
            found = true;
          }
        }
      }
      expect(found, isTrue, reason: 'the started tool must be recorded');
      expect(tool!.state, ToolState.done,
          reason: 'a late tool.complete must flip the owning tool to done');
    });

    test('no duplicate tool chip is minted when a start is re-emitted',
        () async {
      final gw = R10Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();

      // tool.start for tool-1, sealed, then a NEW segment (fresh tail).
      gw.emit('tool.start', {'name': 'terminal', 'tool_id': 'tool-1'});
      gw.emit('message.interim', {'text': 'seg1', 'type': 'final'});
      gw.emit('message.start', {});

      // A re-emitted tool.start for the SAME tool_id (reconnect replay) must
      // NOT mint a second chip in the new segment.
      gw.emit('tool.start', {'name': 'terminal', 'tool_id': 'tool-1'});

      await Future<void>.delayed(Duration.zero); // let the sync stream drain

      var count = 0;
      for (final m in store.messages) {
        count += m.tools.where((t) => t.toolId == 'tool-1').length;
      }
      expect(count, 1,
          reason: 'a re-emitted tool.start for a known id must not duplicate');
    });
  });

  // ── Feature 1: Markdown render toggle + assistant rendering ──────────

  group('markdown rendering toggle', () {
    const sample = '# Heading\n\nSome **bold** text';

    testWidgets('assistant markdown renders rich text when ON (default)',
        (tester) async {
      await tester.pumpWidget(
          MarkdownPreference(enabled: ValueNotifier<bool>(true),
              child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: MessageBubble(
            message: ChatMessage(role: 'assistant', text: sample),
            isUser: false),
      )));
      await tester.pump();

      // With markdown ON, a MarkdownBody is present and the raw source
      // markers are NOT rendered literally (they are formatted).
      expect(find.byType(MarkdownBody), findsOneWidget);
      expect(find.text('Some **bold** text'), findsNothing);
      expect(find.text('Heading'), findsOneWidget);
    });

    testWidgets('assistant markdown renders plain text when OFF', (tester) async {
      await tester.pumpWidget(
          MarkdownPreference(enabled: ValueNotifier<bool>(false),
              child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: MessageBubble(
            message: ChatMessage(
                role: 'assistant', text: '# Heading\n\nSome **bold** text'),
            isUser: false),
      )));
      await tester.pump();

      // With markdown OFF, no MarkdownBody and the raw text is shown verbatim
      // in a plain SelectableText.
      expect(find.byType(MarkdownBody), findsNothing);
      expect(find.text('# Heading\n\nSome **bold** text'), findsOneWidget);
    });

    testWidgets('user messages are always plain text (never markdown)',
        (tester) async {
      await tester.pumpWidget(
          MarkdownPreference(enabled: ValueNotifier<bool>(true),
              child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: MessageBubble(
            message: ChatMessage(role: 'user', text: 'my # question'),
            isUser: true),
      )));
      await tester.pump();

      expect(find.byType(MarkdownBody), findsNothing);
      expect(find.text('my # question'), findsOneWidget);
    });
  });

  // ── Feature 2: the persistent goal bar ───────────────────────────────

  group('goal bar', () {
    testWidgets('shows a persistent bar when a goal is active', (tester) async {
      final gw = R10Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      store.setGoalForTest(
          GoalStatus(status: 'active', title: 'ship the build',
              updatedAt: DateTime.now()));

      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();

      expect(find.text('ship the build'), findsOneWidget);
      expect(find.text('Goal'), findsWidgets,
          reason: 'the goal label must be present in the bar');
    });

    testWidgets('hides the bar entirely when there is no goal', (tester) async {
      final gw = R10Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      expect(store.activeGoal, isNull);

      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();

      expect(find.text('Goal'), findsNothing,
          reason: 'with no goal the bar must not render');
    });
  });
}
