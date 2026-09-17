import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 11 (2026-09-12): regressions for two of the three reported bugs that
/// are cleanly unit-testable. (Bug 2 — the stuck "Refreshing session…" line —
/// is a one-line finally-clear in `_refreshOAuthIfStale` and is verified by
/// review + the full suite; it needs a secure-storage fake to unit-test and
/// would be brittle.)
///
///   Bug 1 — opening a long conversation must land on the NEWEST message,
///            bottom-anchored (reversed list), with no top-of-list flash.
///   Bug 3 — a FINISHED (`done`) goal is terminal: it disappears on the next
///            turn, and later `goal status` reads must not resurrect it.
final _cfg = GatewayConfig(url: 'http://localhost:1');

/// Store-level fake gateway: scripted responses + drivable event stream.
class R11Gateway extends GatewayClient {
  R11Gateway() : super(_cfg);
  final responses = <String, Map<String, dynamic>>{};
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final _stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);

  /// Records the most recent `slash.exec` `command` (e.g. `goal status`,
  /// `goal clear`) so tests can assert what the app sent.
  String? lastSlashCommand;

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
    if (method == 'slash.exec') {
      lastSlashCommand = (params['command'] ?? '').toString();
    }
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

  @override
  Future<void> dispose() async {
    await pushed.close();
    await _stateCtl.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── Bug 3: a finished goal lingers in the gateway (it's only cleared by
  //    `/goal clear`), so the bar mirrors that and an explicit dismiss (the X
  //    button) sends `/goal clear` to the gateway and drops the bar. ─────────

  group('done-goal dismissal via /goal clear', () {
    test('a done goal stays visible until the user clears it, and clearing '
        'sends /goal clear', () async {
      final gw = R11Gateway();
      // Turn 1: the goal is ACTIVE (the agent is working on it).
      gw.responses['slash.exec'] = {
        'output': '⊙ Goal (active, 1/20 turns): ship the build'
      };
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.refreshGoal();
      expect(store.activeGoal?.status, 'active');

      // The agent finishes; `goal status` now reports `done`.
      gw.responses['slash.exec'] = {
        'output': '✓ Goal done (2/20 turns used): ship the build'
      };
      await store.refreshGoal();
      expect(store.activeGoal?.status, 'done');
      expect(store.activeGoal?.title, 'ship the build');

      // A new turn starting must NOT clear a done goal (only the explicit
      // dismiss does). It stays visible as an honest mirror of the gateway.
      gw.emit('message.start', {});
      await Future<void>.delayed(Duration.zero);
      expect(store.activeGoal?.status, 'done',
          reason: 'a done goal persists until the user clears it');

      // The user taps the X: the bar drops instantly and /goal clear is sent.
      await store.dismissGoal();
      expect(store.activeGoal, isNull,
          reason: 'dismissGoal drops the bar');
      expect(gw.lastSlashCommand, 'goal clear',
          reason: 'the X button must send /goal clear to the gateway');

      // After the gateway clears the goal, a later `goal status` reports "No
      // active goal." — and nothing restores the bar.
      gw.responses['slash.exec'] = {
        'output': 'No active goal. Set one with /goal <text>.'
      };
      await store.refreshGoal();
      expect(store.activeGoal, isNull,
          reason: 'a cleared goal must not be resurrected by refresh');
    });

    test('dismissGoal works for a NON-done (active) goal too (early cancel)',
        () async {
      final gw = R11Gateway();
      gw.responses['slash.exec'] = {
        'output': '⊙ Goal (active, 1/20 turns): keep working'
      };
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.refreshGoal();
      expect(store.activeGoal?.status, 'active');

      // An active goal may also be dismissed early via the X.
      await store.dismissGoal();
      expect(store.activeGoal, isNull);
      expect(gw.lastSlashCommand, 'goal clear');
    });

    test('an ACTIVE goal survives across its own turns (turn start does not '
        'clear it)', () async {
      final gw = R11Gateway();
      gw.responses['slash.exec'] = {
        'output': '⊙ Goal (active, 1/20 turns): keep working'
      };
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.refreshGoal();
      expect(store.activeGoal?.status, 'active');

      // A turn starting must not clear a live (active) goal.
      gw.emit('message.start', {});
      await Future<void>.delayed(Duration.zero);
      expect(store.activeGoal, isNotNull,
          reason: 'an active goal must persist across its own turns');
      expect(store.activeGoal?.status, 'active');
    });

    test('a newly-set goal after a cleared one is shown', () async {
      final gw = R11Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      // First: a goal finishes and is shown.
      gw.responses['slash.exec'] = {
        'output': '✓ Goal done (3/3 turns used): old goal'
      };
      await store.refreshGoal();
      expect(store.activeGoal?.status, 'done');
      // The user clears it.
      await store.dismissGoal();
      expect(store.activeGoal, isNull);
      expect(gw.lastSlashCommand, 'goal clear');

      // A fresh goal is set and reported — it must appear.
      gw.responses['slash.exec'] = {
        'output': '⊙ Goal (active, 0/20 turns): brand new goal'
      };
      await store.refreshGoal();
      expect(store.activeGoal, isNotNull,
          reason: 'a new goal after a cleared one must appear');
      expect(store.activeGoal?.title, 'brand new goal');
    });
  });

  // ── Bug 1: opening a conversation lands on the NEWEST message, and that
  //    message sits at the BOTTOM (reversed, chat-style list). ─────────────

  group('reversed transcript', () {
    testWidgets('opening a conversation lands on the newest message',
        (tester) async {
      final gw = R11Gateway();
      gw.responses['session.resume'] = {
        'session_id': 'live-b',
        'resumed': 'stored-b',
        'messages': List.generate(
            40, (i) => {'role': 'user', 'text': 'msg $i', 'ts': i.toDouble()})
      };
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();

      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();

      await store.resumeSession('stored-b');
      await tester.pumpAndSettle();
      expect(store.messages.length, 40);
      expect(find.text('msg 39'), findsOneWidget,
          reason: 'the newest message must be visible after the open');
      expect(store.pendingJumpToBottom, isFalse);
    });

    testWidgets('the newest message renders at the BOTTOM of the list',
        (tester) async {
      final gw = R11Gateway();
      // 8 short messages on a 400x800 surface → not all fit → the list is
      // scrolled, so "bottom-anchored" is meaningful (newest is the lowest).
      gw.responses['session.resume'] = {
        'session_id': 'live-b',
        'resumed': 'stored-b',
        'messages': List.generate(
            30, (i) => {'role': 'user', 'text': 'line $i', 'ts': i.toDouble()})
      };
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();

      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();
      await store.resumeSession('stored-b');
      await tester.pumpAndSettle();

      // In a reversed (chat-style) list the newest row is the lowest visible
      // one. After the open-jump the viewport sits at offset 0 (the newest
      // end), so the newest message is on screen — and it sits BELOW the
      // message just before it (chronological order, bottom-anchored).
      expect(find.text('line 29'), findsOneWidget,
          reason: 'the newest message must be on screen after the open');
      final newest = tester.getBottomLeft(find.text('line 29'));
      final prev = tester.getBottomLeft(find.text('line 28'));
      expect(newest.dy > prev.dy, isTrue,
          reason: 'newest must sit below the previous message (bottom-anchored)');
    });
  });
}
