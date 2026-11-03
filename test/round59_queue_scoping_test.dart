import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/store/chat_store.dart';

/// /queue scoping: a queued message belongs to the conversation it was made
/// in, and must neither DISPLAY in nor DRAIN INTO another conversation.
///
/// Angela's 1.4.0 report: "when using the /queue command, the queue displays
/// on all conversations, it doesn't stick to the original conversation that it
/// was paired to." The QueuedPrompt model already carries `sessionId` (and
/// says so in its doc comment: "so a queue survives switching away and back"),
/// but nothing ever filters by it: the getter, the strip, the drain, and the
/// restart restore all treat the queue as one global pile. So a message queued
/// in conversation A shows up under B AND gets submitted into B at the end of
/// B's turn.
///
/// The fake models TWO live sessions with the gateway's real id spaces
/// (stored key vs runtime sid), because a single-session fake cannot express
/// "paired to the original conversation" at all.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class QGateway extends GatewayClient {
  QGateway() : super(_cfg);
  final calls = <(String, Map<String, dynamic>)>[];
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => pushed.stream;
  @override
  Stream<GwConnectionState> get stateChanges => const Stream.empty();
  @override
  Future<void> connect({bool isReconnect = false}) async {}

  /// Runtime sids handed out per resume. The REAL gateway re-mints a runtime
  /// sid on every resume (a WS detach orphans the old one), so a pairing that
  /// keyed on the runtime sid would break the moment the owning conversation
  /// is left and re-opened. The fake models that: stored key -> sids issued,
  /// in resume order, then live on the most recent one.
  final Map<String, List<String>> _minted = {};
  /// stored key -> a turn is running there (set on prompt.submit, cleared on
  /// emit of message.complete) so `session.resume` reports `running` like the
  /// real gateway: a queue must not drain into a conversation whose resume
  /// says a turn is live.
  final Set<String> _running = {};

  String _storedForSid(String sid) {
    for (final e in _minted.entries) {
      if (e.value.contains(sid)) return e.key;
    }
    return '';
  }

  String _sidFor(String stored) {
    final list = _minted.putIfAbsent(stored, () => []);
    list.add('$stored-r${list.length + 1}');
    return list.last;
  }

  String _currentSid(String stored) {
    final list = _minted[stored] ?? [];
    return list.isEmpty ? '' : list.last;
  }

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    calls.add((method, params));
    if (method == 'prompt.submit') {
      final stored = _storedForSid((params['session_id'] ?? '').toString());
      if (stored.isNotEmpty) _running.add(stored);
    }
    return switch (method) {
      'session.resume' => {
          'session_id': _sidFor((params['session_id'] ?? '').toString()),
          'resumed': params['session_id'],
          'running': _running.contains(params['session_id']),
          'messages': const <Map<String, dynamic>>[],
        },
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'session.active_list' => {
          'sessions': [
            for (final e in _minted.entries)
              if (_currentSid(e.key).isNotEmpty)
                {'id': _currentSid(e.key), 'session_key': e.key},
          ],
        },
      'prompt.submit' => {'status': 'streaming'},
      'session.usage' => {'context_used': 1000, 'context_max': 128000},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data, {String sid = 'stored-a-r1'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  /// Submits made against a given RUNTIME sid (the id prompt.submit carries).
  List<String> submittedFor(String runtimeSid) => [
        for (final c in calls)
          if (c.$1 == 'prompt.submit' && c.$2['session_id'] == runtimeSid)
            (c.$2['text'] ?? '').toString()
      ];

  @override
  Future<void> dispose() async {
    await pushed.close();
  }
}

Future<(QGateway, ChatStore)> _open(String stored) async {
  SharedPreferences.setMockInitialValues({});
  final gw = QGateway();
  final store = ChatStore(config: _cfg, client: gw);
  addTearDown(store.dispose);
  await store.connect();
  await store.resumeSession(stored);
  return (gw, store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a queue made in conversation A is not shown while B is on screen',
      () async {
    final (gw, store) = await _open('stored-a');
    // Turn running in A; queue a follow-up in A.
    gw.emit('message.start', {}, sid: 'stored-a-r1');
    await store.send('working in A');
    store.enqueuePrompt('follow-up for A');
    expect(store.queuedPrompts, hasLength(1));

    // Switch to B. The queue belongs to A, so the strip on B must be empty.
    await store.resumeSession('stored-b');
    expect(store.queuedPrompts, isEmpty,
        reason: 'the queue is paired to the conversation it was made in');

    // Switching back restores it — the pairing, not a deletion.
    await store.resumeSession('stored-a');
    expect(store.queuedPrompts.map((q) => q.text), contains('follow-up for A'));
  });

  test('a queue made in A never drains into B when B ends its turn', () async {
    final (gw, store) = await _open('stored-a');
    gw.emit('message.start', {}, sid: 'stored-a-r1');
    await store.send('working in A');
    store.enqueuePrompt('follow-up for A');

    // Move to B and run a turn there; when B's turn ends, A's queue must NOT
    // fire into B.
    await store.resumeSession('stored-b');
    gw.emit('message.start', {}, sid: 'stored-b-r1');
    await store.send('working in B');
    gw.emit('message.complete', {'text': 'done B'}, sid: 'stored-b-r1');
    await pumpEventQueue();

    expect(gw.submittedFor('stored-b-r1'), isNot(contains('follow-up for A')),
        reason: 'a queued message must never run in another conversation');
    // It is still waiting, paired to A.
    expect(store.queuedPrompts, isEmpty,
        reason: 'not visible while B is on screen...');
    await store.resumeSession('stored-a');
    expect(store.queuedPrompts.map((q) => q.text), contains('follow-up for A'),
        reason: '...but still queued for A');
  });

  test("A's queue drains when A's own turn ends (pairing does not strand it)",
      () async {
    final (gw, store) = await _open('stored-a');
    gw.emit('message.start', {}, sid: 'stored-a-r1');
    await store.send('working in A');
    store.enqueuePrompt('follow-up for A');

    gw.emit('message.complete', {'text': 'done A'}, sid: 'stored-a-r1');
    await pumpEventQueue();

    expect(gw.submittedFor('stored-a-r1'), contains('follow-up for A'),
        reason: 'the drain is keyed to the OWNING conversation, not every one');
  });

  test('a queue with no owning conversation still drains into the active one',
      () async {
    // Legacy persisted entries (sessionId empty) keep the old behavior:
    // "Empty means it belongs to whatever session is active when it drains."
    SharedPreferences.setMockInitialValues({
      'queued_prompts_v1':
          '[{"id":"q-old","text":"legacy entry","session":"","at":1}]',
    });
    final gw = QGateway();
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();
    // stored-a opens IDLE, and the legacy entry has no owning conversation:
    // it drains into the active one, like any queue made while nothing runs.
    await store.resumeSession('stored-a');
    await pumpEventQueue();
    expect(gw.submittedFor('stored-a-r1'), contains('legacy entry'));
    expect(store.queuedPrompts, isEmpty);
  });

  test('a restart keeps each queue entry paired to its conversation', () async {
    SharedPreferences.setMockInitialValues({});
    final gw = QGateway();
    final first = ChatStore(config: _cfg, client: gw);
    await first.connect();
    await first.resumeSession('stored-a');
    gw.emit('message.start', {}, sid: 'stored-a-r1');
    await first.send('turn in A');
    first.enqueuePrompt('paired to A');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    first.dispose();

    final secondGw = QGateway();
    final second = ChatStore(config: _cfg, client: secondGw);
    addTearDown(second.dispose);
    await second.connect();
    // Restore lands, but B is on screen: A's queue must not surface here, and
    // must not fire into B.
    await second.resumeSession('stored-b');
    await pumpEventQueue();
    expect(second.queuedPrompts, isEmpty,
        reason: 'restart must not un-pair the queue from A');
    expect(secondGw.submittedFor('stored-b-r1'), isNot(contains('paired to A')));

    // Re-opening A (idle after the restart) finally runs it, INTO A.
    await second.resumeSession('stored-a');
    await pumpEventQueue();
    expect(secondGw.submittedFor('stored-a-r1'), contains('paired to A'),
        reason: 'the pairing survives restart and drains into its OWN '
            'conversation, never another');
  });
}
