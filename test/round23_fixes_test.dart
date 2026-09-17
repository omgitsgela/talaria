import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 23 (2026-09-16) — three defects found while triaging on-device
/// reports. Each one is pinned here at the store level.
///
/// 1. **Model switch that never reached the conversation.** The gateway applies
///    `config.set model` to the LIVE session named by `session_id`
///    (`tui_gateway/methods_config_set.py`: `session = _sessions.get(params.
///    get("session_id", ""))`). When that lookup MISSES — a stale runtime id
///    reaped after a WS detach, or a draft with no session yet — `_set_model`
///    still returns a SUCCESS envelope while validating the pick against a
///    throwaway record (`{"agent": None}`), so the header showed the new model
///    and the next prompt ran the old one.
/// 2. **Blank transcript on load.** A resume whose display history is still
///    hydrating answers with an empty `messages` list plus a truthful
///    `message_count`, and a `session.history` read can come back empty for a
///    record mid-hydration. Merging that empty read used to
///    `removeRange(0, length)` the whole transcript, and a resume that hydrated
///    nothing armed no retry — the conversation stayed blank.
/// 3. **Gray status pill full of irrelevant text.** During a thinking turn the
///    agent relays internal narration as `status.update kind:"lifecycle"`
///    ("Session is free; loading the latest transcript…"), which scrolled in
///    the bottom pill for the entire turn. Desktop parity keeps those out.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class R23Gateway extends GatewayClient {
  R23Gateway() : super(_cfg);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];

  int _runtimeSeq = 0;
  String get lastRuntime => 'rt-$_runtimeSeq';

  /// Rows `session.active_list` reports. Empty => the runtime id is stale.
  List<Map<String, dynamic>> activeRows = const [];
  /// When true, `session.active_list` reports the CURRENT runtime id as live
  /// (the gateway's real behaviour after a re-attach), instead of the static
  /// [activeRows].
  bool reportLiveRuntime = false;
  /// Rows `session.history` reports.
  List<Map<String, dynamic>> historyRows = const [];
  /// When set, `session.resume` answers with NO messages + this count (the
  /// hydrating / deferred shape) instead of the two stored rows.
  int? resumeOmitsRowsWithCount;
  /// When true, `prompt.submit` fails (transport-style) so a failure path can
  /// be exercised.
  bool failSubmit = false;
  /// Fail the FIRST `config.set` with 4001 (the gateway's "named session is
  /// gone" answer), then succeed -- exercises the recover-and-retry path.
  bool failFirstConfigSetWith4001 = false;
  int configSetCount = 0;

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => pushed.stream;
  @override
  Stream<GwConnectionState> get stateChanges => stateCtl.stream;
  @override
  Future<void> connect({bool isReconnect = false}) async {
    stateCtl.add(GwConnectionState.open);
  }

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    calls.add((method, params));
    switch (method) {
      case 'session.resume':
        _runtimeSeq++;
        final omitted = resumeOmitsRowsWithCount;
        return {
          'session_id': lastRuntime,
          'resumed': params['session_id'],
          'message_count': omitted ?? 2,
          'messages': omitted != null
              ? const <Map<String, dynamic>>[]
              : const [
                  {'role': 'user', 'text': 'stored question'},
                  {'role': 'assistant', 'text': 'stored answer'},
                ],
          'info': {'model': 'test-model'},
        };
      case 'session.history':
        return {'count': historyRows.length, 'messages': historyRows};
      case 'session.active_list':
        return {
          'sessions': reportLiveRuntime ? _live(lastRuntime) : activeRows,
        };
      case 'session.list':
        return {'sessions': const <Map<String, dynamic>>[]};
      case 'prompt.submit':
        if (failSubmit) throw GatewayError('simulated transport blip', code: 4009);
        return {'status': 'streaming'};
      case 'config.set':
        configSetCount++;
        if (failFirstConfigSetWith4001 && configSetCount == 1) {
          throw GatewayError('session not found', code: 4001);
        }
        return {
          'key': params['key'],
          'value': params['value'],
          'scope': 'session',
        };
      default:
        return {};
    }
  }

  int countOf(String method) => calls.where((c) => c.$1 == method).length;

  Map<String, dynamic>? lastParams(String method) {
    for (final c in calls.reversed) {
      if (c.$1 == method) return c.$2;
    }
    return null;
  }

  void emit(String type, Map<String, dynamic> data, {String sid = ''}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
    await stateCtl.close();
  }
}

/// The live row the gateway reports for a runtime id.
List<Map<String, dynamic>> _live(String id) =>
    [{'id': id, 'session_id': id, 'model': 'test-model'}];

Future<void> _settle([int ms = 20]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('model switch targets the live conversation (round 23)', () {
    test('a stale runtime id is re-attached before the switch lands', () async {
      final gw = R23Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');
      expect(store.activeSessionId, 'rt-1');
      // The gateway reaped the runtime on a socket drop: our id is gone from
      // the live table, so a bare `config.set model` would be applied to a
      // throwaway record and the conversation would keep its old model.
      gw.activeRows = const [];

      final res = await store.setModel('qwen38 --provider llamacpp-qwen38');

      expect(res.isSuccess, isTrue);
      expect(gw.countOf('session.resume'), 2,
          reason: 'the stale runtime must be re-attached before switching');
      final cfg = gw.lastParams('config.set');
      expect(cfg, isNotNull);
      expect(cfg!['session_id'], 'rt-2',
          reason: 'the switch must name the FRESH runtime id, not the reaped '
              'one (the gateway silently no-ops on an unknown sid)');
      expect(cfg['value'], 'qwen38 --provider llamacpp-qwen38',
          reason: 'the pick must be forwarded verbatim');
    });

    test('a 4001 from the switch re-attaches and retries once', () async {
      final gw = R23Gateway()
        ..failFirstConfigSetWith4001 = true
        // The gateway lists the re-attached runtime as live; without this the
        // fake would advertise the pre-reattach id and the app would (also
        // correctly) re-attach a second time.
        ..reportLiveRuntime = true;
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');

      final res = await store.setModel('qwen38');

      expect(res.isSuccess, isTrue,
          reason: 'the stale-session answer must be recovered, not surfaced '
              'as a user-facing failure');
      expect(gw.configSetCount, 2, reason: 'one rejected switch + one retry');
      expect(gw.countOf('session.resume'), 2,
          reason: 'the retry must be preceded by a session.resume of the '
              'STORED id');
    });

    test('a live runtime id is switched in place (no needless re-attach)',
        () async {
      final gw = R23Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');
      expect(store.activeSessionId, 'rt-1');
      gw.activeRows = _live('rt-1');

      final res = await store.setModel('qwen38');

      expect(res.isSuccess, isTrue);
      expect(gw.countOf('session.resume'), 1,
          reason: 'a live conversation must not be re-resumed for a switch');
      expect(gw.lastParams('config.set')!['session_id'], 'rt-1');
    });
  });

  group('blank conversation view (round 23)', () {
    test('an empty history read never blanks a populated transcript',
        () async {
      final gw = R23Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');
      expect(store.messages.length, 2);
      // The conversation is live (no stale-recovery noise) but the background
      // read now answers with NO rows — a mid-hydration record.
      gw.activeRows = _live('rt-1');
      gw.historyRows = const [];

      gw.emit('sessions.changed', const {}, sid: 'rt-1');
      await _settle(1100); // the pull is debounced 750ms

      expect(store.messages.length, 2,
          reason: 'an empty history read must never wipe what is on screen; '
              'merging it used to removeRange(0, length) the whole transcript');
    });

    test('a resume that hydrates no rows arms a history pull that fills in',
        () async {
      final gw = R23Gateway()
        ..resumeOmitsRowsWithCount = 2
        ..activeRows = _live('rt-1')
        ..historyRows = const [
          {'role': 'user', 'text': 'stored question'},
          {'role': 'assistant', 'text': 'stored answer'},
        ];
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');

      expect(store.messages, isEmpty,
          reason: 'the resume payload itself carried no rows');
      await _settle(1100); // the armed pull fires after the 750ms debounce

      expect(store.messages.length, 2,
          reason: 'a blank resume must arm the read-only history pull instead '
              'of leaving the view empty until an unrelated broadcast');
    });
  });

  group('status pill ignores internal narration (round 23)', () {
    test('lifecycle chatter stays out; meaningful kinds still surface',
        () async {
      final gw = R23Gateway()..activeRows = _live('rt-1');
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');
      final sid = store.activeSessionId!;
      expect(store.statusLine, isEmpty);

      gw.emit(
          'status.update',
          {
            'kind': 'lifecycle',
            'text': 'Session is free; loading the latest transcript…',
          },
          sid: sid);
      expect(store.statusLine, isEmpty,
          reason: 'the agent\'s internal narration must not scroll in the '
              'transcript pill for the whole turn');

      gw.emit('status.update',
          {'kind': 'compacting', 'text': 'Compressing context…'},
          sid: sid);
      expect(store.statusLine, 'Compressing context…',
          reason: 'compaction progress is actionable and must still surface');
    });
  });

  group('the gray status pill goes away during a plain turn (round 23)', () {
    test('tool chatter never reaches the status line', () async {
      final gw = R23Gateway()..activeRows = _live('rt-1');
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');
      final sid = store.activeSessionId!;

      // The reported "stuck on using terminal" text came from tool events.
      gw.emit('tool.start', {'name': 'terminal', 'tool_id': 't1'}, sid: sid);
      expect(store.statusLine, isEmpty,
          reason: 'a started tool must not park "Using terminal…" in the UI');
      gw.emit('tool.progress', {'tool_id': 't1', 'text': 'ls -la /tmp'}, sid: sid);
      expect(store.statusLine, isEmpty,
          reason: 'raw tool output belongs on the tool chip, not the status');
    });

    test('a history pull is deferred while a compaction rewrites the session',
        () async {
      final gw = R23Gateway()..activeRows = _live('rt-1');
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');
      expect(store.messages.length, 2);
      final sid = store.activeSessionId!;

      // Compaction starts: durable rows are mid-rewrite, so a read now can
      // observe a half-applied state (the reported disappearing view).
      gw.emit('status.update',
          {'kind': 'compacting', 'text': 'Compressing context…'}, sid: sid);
      gw.historyRows = const [];
      gw.emit('sessions.changed', const {}, sid: sid);
      await _settle(1100);
      expect(store.messages.length, 2,
          reason: 'the transcript on screen must survive a mid-rewrite read');
      expect(gw.countOf('session.history'), 0,
          reason: 'no pull may run while the rewrite is in flight');

      // Compaction done: the deferred pull runs and shows the summarized view.
      gw.historyRows = const [
        {'role': 'assistant', 'text': 'summary of the whole conversation'},
      ];
      gw.emit('status.update',
          {'kind': 'compacted', 'text': '✓ Context compression complete'},
          sid: sid);
      await _settle(1100);
      expect(gw.countOf('session.history'), greaterThan(0),
          reason: 'the pull deferred during the rewrite must run afterwards');
      expect(store.messages.length, 1);
    });

    test('a failure is raised as a notice, never silently dropped', () async {
      final gw = R23Gateway()..failSubmit = true;
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');
      final seen = <String>[];
      final sub = store.notices.listen(seen.add);
      addTearDown(sub.cancel);

      final ok = await store.send('hello');

      expect(ok, isFalse);
      expect(seen, isNotEmpty,
          reason: 'with the status pill gone a failure must still reach the '
              'user (SnackBar), not vanish');
      expect(seen.first, contains('simulated transport blip'));
      expect(store.statusLine, contains('simulated transport blip'));
    });

    testWidgets('no gray chip during a plain streaming turn', (tester) async {
      tester.view.physicalSize = const Size(1260, 2700);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final gw = R23Gateway()..activeRows = _live('rt-1');
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();
      await store.resumeSession('stored-x');
      await tester.pump();

      await store.send('hello');
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-status')), findsNothing,
          reason: 'the reported gray box is gone from the transcript');

      // It must not come back for a "meaningful" status either: the box is
      // removed outright, its text no longer renders anywhere in the transcript.
      gw.emit('status.update',
          {'kind': 'compacting', 'text': 'Compressing context…'},
          sid: store.activeSessionId!);
      await tester.pump();
      expect(find.byKey(const ValueKey('turn-status')), findsNothing);
      expect(find.text('Compressing context…'), findsNothing);
    });
  });
}
