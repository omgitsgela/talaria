import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/models/goal_status.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 47: two reported defects that turned out to be the same class of
/// problem on different surfaces — the app could not tell a REQUEST apart from
/// a RESPONSE, and it discarded the result of an attach.
///
///   1. Attaching a file: no confirmation, then "session isn't found" on send.
///      The attach RPC had no recovery from a stale runtime id (every other
///      transcript RPC did), it returned a bare error string the composer threw
///      away, and there was no size ceiling to explain a rejected large file.
///   2. Approvals and the sudo password prompt could never appear. The gateway
///      asks for both with server→client REQUEST frames; the client treated
///      every frame carrying an `id` as a response to one of its own calls,
///      found no pending call, and returned — dropping the request silently
///      while the agent waited for its timeout.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class FakeGateway extends GatewayClient {
  FakeGateway() : super(_cfg);

  final _events = StreamController<GatewayEvent>.broadcast();
  final _requests = StreamController<ServerRequest>.broadcast();

  final List<Map<String, dynamic>> replies = [];
  final Map<String, List<Map<String, dynamic>>> calls = {};
  Object? failOnce;
  int failCount = 0;

  /// Set to model the gateway having REAPED the runtime session (a dropped
  /// socket does this). The dead id stays dead: every runtime-scoped RPC is
  /// rejected with 4001 until the client re-attaches, at which point a genuinely
  /// fresh runtime id is handed out. A one-shot failure cannot model this
  /// because the send path's own retry loop would absorb it by retrying the
  /// SAME dead id, which is precisely the bug being fixed.
  bool staleRuntime = false;
  String? _freshSid;

  /// The stored key the gateway hands back from session.create, when it gives
  /// one. A real gateway may omit it, which is why the active_list reconcile
  /// also adopts it.
  String? sessionKeyInCreate;

  /// Rows for session.active_list: the runtime id lives in `id` and the stored
  /// key in `session_key`.
  List<Map<String, dynamic>> activeListRows = const [];

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => _events.stream;
  @override
  Stream<GwConnectionState> get stateChanges => const Stream.empty();
  @override
  Stream<ServerRequest> get serverRequests => _requests.stream;
  @override
  Future<void> connect({bool isReconnect = false}) async {}

  @override
  void respondToServerRequest(Object id, Map<String, dynamic> result) {
    replies.add({'id': id, 'result': result});
  }

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    calls.putIfAbsent(method, () => []).add(params);
    if (failOnce != null && failCount > 0) {
      failCount--;
      throw failOnce!;
    }
    if (method == 'session.create' || method == 'session.resume') {
      if (staleRuntime) _freshSid = 'sid-fresh';
      return {
        'session_id': staleRuntime ? 'sid-fresh' : 'sid-live',
        if (sessionKeyInCreate != null) 'session_key': sessionKeyInCreate,
      };
    }
    if (method == 'session.active_list') {
      return {'sessions': activeListRows};
    }
    if (staleRuntime) {
      final sid = params['session_id'];
      if (sid != _freshSid) {
        throw GatewayError('session not found', code: 4001);
      }
    }
    if (method == 'file.attach') {
      return {'ref_text': '@file:staged/report.pdf', 'name': 'report.pdf'};
    }
    return const {};
  }

  void pushEvent(GatewayEvent ev) => _events.add(ev);
  void pushRequest(ServerRequest req) => _requests.add(req);

  @override
  Future<void> dispose() async {
    await _events.close();
    await _requests.close();
    await super.dispose();
  }
}

ChatStore fresh(FakeGateway gw) => ChatStore(config: _cfg, client: gw);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── 0. Classifying an inbound frame: THE defect ──────────────────
  // A request and a response to our own call both carry `id`. Only a request
  // carries `method`. Getting this wrong is what dropped every approval.

  test('an approval frame is a request, not a response', () {
    // The exact wire shape the gateway writes (server_requests.py:56).
    final req = serverRequestFromFrame(const <String, dynamic>{
      'jsonrpc': '2.0',
      'id': 41,
      'method': 'approval',
      'params': {
        'request_id': 'req-1',
        'command': 'rm -rf /tmp/x',
        'tool_name': 'terminal',
        'choices': ['once', 'session', 'always', 'deny'],
      },
    });
    expect(req, isNotNull);
    expect(req!.method, 'approval');
    expect(req.requestId, 'req-1');
    expect(req.approvalChoices, ['once', 'session', 'always', 'deny']);
  });

  test('a response to one of our own calls is not a request', () {
    expect(serverRequestFromFrame(const <String, dynamic>{
      'id': 3,
      'result': {'ok': true},
    }), isNull);
  });

  test('an event is not a request', () {
    expect(serverRequestFromFrame(const <String, dynamic>{
      'method': 'event',
      'params': {'type': 'message.delta'},
    }), isNull);
  });

  test('a frame without an id is not a request', () {
    expect(serverRequestFromFrame(const <String, dynamic>{
      'method': 'approval',
      'params': <String, dynamic>{},
    }), isNull);
  });

  test('sudo expects one string, clarify does not', () {
    final sudo = serverRequestFromFrame(const <String, dynamic>{
      'id': 9,
      'method': 'sudo',
      'params': {'command': 'sudo systemctl restart nginx'},
    });
    expect(sudo!.wantsValue, isTrue);
    final clarify = serverRequestFromFrame(const <String, dynamic>{
      'id': 10,
      'method': 'clarify',
      'params': {'question': 'which one?'},
    });
    expect(clarify!.wantsValue, isFalse);
  });

  // ── 1. Attaching a file ──────────────────────────────────────────

  test('a successful attach is reported with its reference', () async {
    final gw = FakeGateway();
    final store = fresh(gw);
    addTearDown(store.dispose);

    final ref = await store.attachFileBytes(
        List<int>.filled(32, 7), name: 'report.pdf');

    expect(ref, '@file:staged/report.pdf');
    expect(store.attachError, isNull);
    expect(store.attachmentDetails.map((a) => a.filename), contains('report.pdf'));
  });

  test('a stale runtime id is recovered, not reported as session-not-found',
      () async {
    final gw = FakeGateway();
    final store = fresh(gw);
    addTearDown(store.dispose);

    // Establish a stored conversation, then make the first attach fail the way
    // a restarted gateway does.
    await store.resumeSession('stored-1', silent: true);
    gw.failOnce = GatewayError('session not found', code: 4001);
    gw.failCount = 1;

    final ref =
        await store.attachFileBytes(List<int>.filled(16, 1), name: 'a.txt');

    // Recovered and retried rather than surfacing the bare session error.
    expect(ref, isNotEmpty);
    expect(store.attachError, isNull);
    expect(gw.calls['file.attach']!.length, 2,
        reason: 'the first attempt 4001s, the retry succeeds');
  });

  test('a failed attach says why and yields no reference', () async {
    final gw = FakeGateway();
    final store = fresh(gw);
    addTearDown(store.dispose);

    gw.failOnce = GatewayError('boom', code: 5000);
    gw.failCount = 9;

    final ref =
        await store.attachFileBytes(List<int>.filled(16, 1), name: 'notes.txt');

    // Returning an error string as though it were a reference is what made the
    // SEND look like the broken step: nothing said the attach had failed.
    expect(ref, isEmpty);
    expect(store.attachError, contains('notes.txt'));
    expect(store.attachmentDetails, isEmpty);
    store.clearAttachError();
    expect(store.attachError, isNull);
  });

  test('an empty file is refused before any request', () async {
    final gw = FakeGateway();
    final store = fresh(gw);
    addTearDown(store.dispose);

    final ref = await store.attachFileBytes(<int>[], name: 'empty.txt');
    expect(ref, isEmpty);
    expect(store.attachError, contains('empty'));
    expect(gw.calls.containsKey('file.attach'), isFalse);
  });

  test('the size ceiling sits below the gateway frame limit', () {
    // The gateway raises its websocket frame limit for attachments to 384 MiB
    // (hermes_cli/web_server.py::_DESKTOP_ATTACHMENT_WS_MAX_BYTES) and a data
    // URL inflates the bytes by 4/3, so the file ceiling must leave room.
    const gatewayFrameLimit = 384 * 1024 * 1024;
    expect(ChatStore.maxAttachBytes, lessThan(gatewayFrameLimit));
    expect(ChatStore.maxAttachBytes * 4 ~/ 3, lessThan(gatewayFrameLimit));
  });

  test('sizes read as sizes', () {
    expect(ChatStore.humanSize(512), '512 bytes');
    expect(ChatStore.humanSize(2048), '2 KB');
    expect(ChatStore.humanSize(5 * 1024 * 1024), '5.0 MB');
    expect(ChatStore.humanSize(3 * 1024 * 1024 * 1024), '3.0 GB');
  });

  // ── 2. Requests the gateway is blocked on ────────────────────────

  test('an approval request arms the existing pending-request card', () async {
    final gw = FakeGateway();
    final store = fresh(gw);
    addTearDown(store.dispose);

    gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
      'id': 7,
      'method': 'approval',
      'params': {
        'request_id': 'req-abc',
        'command': 'rm -rf /tmp/x',
        'tool_name': 'terminal',
        'choices': ['once', 'session', 'always', 'deny'],
      },
    })!);
    await Future<void>.delayed(Duration.zero);

    // Fed through the SAME state the clarify/approval card already renders and
    // answers through the RPC that requires a request_id.
    expect(store.pendingRequest, isNotNull);
    expect(store.pendingRequest!.type, 'approval.request');
    expect(store.pendingRequest!.payload['request_id'], 'req-abc');
    expect(store.statusLine, 'Waiting for your input…');
  });

  test('a sudo prompt is held and its value goes straight back', () async {
    final gw = FakeGateway();
    final store = fresh(gw);
    addTearDown(store.dispose);

    gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
      'id': 11,
      'method': 'sudo',
      'params': {'command': 'sudo systemctl restart nginx'},
    })!);
    await Future<void>.delayed(Duration.zero);
    expect(store.pendingValueRequest?.method, 'sudo');

    store.respondValue('secret-value');
    expect(store.pendingValueRequest, isNull);
    expect(gw.replies.single['id'], 11);
    expect((gw.replies.single['result'] as Map)['value'], 'secret-value');
  });

  test('a secret prompt names its env var and answers the same way', () async {
    final gw = FakeGateway();
    final store = fresh(gw);
    addTearDown(store.dispose);

    gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
      'id': 12,
      'method': 'secret',
      'params': {'env_var': 'OPENAI_API_KEY', 'prompt': 'Paste the key'},
    })!);
    await Future<void>.delayed(Duration.zero);
    expect(store.pendingValueRequest?.params['env_var'], 'OPENAI_API_KEY');

    store.respondValue('sk-not-a-real-key');
    expect((gw.replies.single['result'] as Map)['value'], 'sk-not-a-real-key');
  });

  test('a prompt this client cannot serve is answered, never left hanging',
      () async {
    final gw = FakeGateway();
    final store = fresh(gw);
    addTearDown(store.dispose);

    // A GUI read is meaningless on a phone, but an unanswered request parks the
    // agent until the gateway's own timeout, which looks like a hung turn.
    gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
      'id': 13,
      'method': 'window.read',
      'params': <String, dynamic>{},
    })!);
    await Future<void>.delayed(Duration.zero);

    expect(gw.replies.single['id'], 13);
    expect((gw.replies.single['result'] as Map)['value'], '');
    expect(store.pendingValueRequest, isNull);
    expect(store.pendingRequest, isNull);
  });

  // ── 3. Is /yolo actually on? ─────────────────────────────────────

  test('the effective approval bypass comes from the gateway', () async {
    final gw = FakeGateway();
    final store = fresh(gw);
    addTearDown(store.dispose);
    await store.resumeSession('stored-1', silent: true);

    expect(store.yoloActive, isFalse);
    gw.pushEvent(const GatewayEvent(
      type: 'session.info',
      sessionId: 'sid-live',
      payload: {'yolo': true, 'model': 'm'},
    ));
    await Future<void>.delayed(Duration.zero);
    expect(store.yoloActive, isTrue,
        reason: 'typing /yolo is not the same as approvals being skipped');

    gw.pushEvent(const GatewayEvent(
      type: 'session.info',
      sessionId: 'sid-live',
      payload: {'yolo': false},
    ));
    await Future<void>.delayed(Duration.zero);
    expect(store.yoloActive, isFalse);
  });

  // ── 4. A created conversation must acquire a STORED id ───────────
  // Without one, 4001 recovery is skipped and notification payloads are empty,
  // so a reply from a notification tap fails with "session not found". The
  // gateway's session.create reply may omit the key, so the authoritative
  // source is the session.active_list reconcile below.

  test('a created conversation adopts the stored key from active_list',
      () async {
    final gw = FakeGateway();
    final store = fresh(gw);
    addTearDown(store.dispose);
    await store.createSession();
    expect(store.activeStoredSessionId, isNull,
        reason: 'the gateway gave no key up front');
    // The roster reconcile is the safety net for a gateway that omits it.
    gw.activeListRows = const [
      {'id': 'sid-live', 'session_key': 'stored-from-list', 'status': 'idle'},
    ];
    await store.loadSessions();
    await store.reconcileActiveTurnStatus();
    expect(store.activeStoredSessionId, 'stored-from-list');
  });

  // ── 5. A reply after a notification tap must recover a dead runtime ──

  test('a reply survives a stale runtime session (the notification-tap case)',
      () async {
    final gw = FakeGateway();
    final store = fresh(gw);
    addTearDown(store.dispose);
    // Open the conversation, as a notification tap does.
    await store.resumeSession('stored-1', silent: true);
    // Now the gateway reaps that runtime session (the socket dropped while the
    // app was backgrounded). The transcript is still on screen from history and
    // _activeSessionId is a dead id, so EVERY submit against it answers 4001
    // until the client re-attaches under a fresh runtime id.
    gw.staleRuntime = true;

    final sent = await store.send('are you there?');

    // The send must heal the stale id and land instead of failing with 4001.
    // NOTE: the fake does not record a call it rejected, so the number of
    // recorded submits cannot count the failed attempt. The proof that the
    // recovery ran is that the send SUCCEEDED at all after a programmed 4001,
    // plus the re-attach the recovery issues.
    expect(sent, isTrue, reason: 'the reply must succeed after recovery');
    expect(gw.calls['session.resume'], isNotEmpty,
        reason: 'the stale runtime id must be re-attached under a fresh one');
    expect(gw.calls['prompt.submit']!.last['text'], 'are you there?');
  });

  // ── 5. An approval belongs to ONE conversation ───────────────────

  test('switching drops the previous conversation goal at once', () async {
    final gw = FakeGateway();
    final store = fresh(gw);
    addTearDown(store.dispose);
    await store.resumeSession('stored-1', silent: true);

    // A /goal persists across many turns, so it is real state on screen.
    store.setGoalForTest(GoalStatus(
        status: 'active',
        title: 'deploy the thing',
        updatedAt: DateTime(2026, 10, 2),
      ));
    expect(store.activeGoal, isNotNull);

    // Switching to a DIFFERENT conversation. Deliberately not awaited: the
    // defect was about what is on screen WHILE the new conversation loads, so
    // the assertion has to be read before the transcript lands.
    final f = store.resumeSession('stored-2', silent: true);
    expect(store.activeGoal, isNull,
        reason: 'the goal bar belongs to the conversation being left, so it '
            'must not sit over a different conversation while it loads');
    expect(store.activeStoredSessionId, 'stored-2',
        reason: 'the loading card resolves its title from the stored id; a '
            'stale one announces the PREVIOUS conversation for the whole load');
    try {
      await f;
    } catch (_) {
      // The switch's own RPCs are not what this test is about.
    }
  });

  test('an approval ALWAYS appears, even from another conversation',
      () async {
    // Deliberately the opposite of what an earlier version asserted. Scoping the
    // card by session id silently hid prompts: the request's session id is not
    // guaranteed to share an id space with ours, and a hidden prompt leaves the
    // agent blocked or withdrawn. Showing it in the wrong place is the lesser
    // harm.
    final gw = FakeGateway();
    final store = fresh(gw);
    addTearDown(store.dispose);
    await store.resumeSession('stored-1', silent: true);

    // Belongs to a different session: no card in the open conversation.
    gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
      'id': 71,
      'method': 'approval',
      'params': {
        'request_id': 'r-other',
        'session_id': 'sid-other',
        'command': 'rm -rf /tmp/y',
      },
    })!);
    await Future<void>.delayed(Duration.zero);
    expect(store.pendingRequest, isNotNull,
        reason: 'a prompt the user cannot see is worse than one shown in the '
            'wrong conversation: the agent stays blocked or is withdrawn');

    // Belongs to THIS session: the card appears, as before.
    gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
      'id': 72,
      'method': 'approval',
      'params': {
        'request_id': 'r-mine',
        'session_id': 'sid-live',
        'command': 'rm -rf /tmp/z',
      },
    })!);
    await Future<void>.delayed(Duration.zero);
    expect(store.pendingRequest, isNotNull);
    expect(store.pendingRequest!.payload['request_id'], 'r-mine');
  });
}
