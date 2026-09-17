import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/app_version.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/main.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/app_model.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 4 (2026-09-11) regressions, one per reported issue:
///   1. stuck "working" indicator / dead stop button → event-driven
///      authoritative reconciliation against session.active_list
///   2. per-conversation status dots in the Sessions roster
///   3. launch splash (logo, tagline, version) and version constants
///   4. mid-turn sends: /queue, /steer and plain text all go through while
///      a turn is running (structured slash dispatch, not empty output)
///   5. conversation switch auto-scrolls to the newest message
///   6. Send + Stop coexist in the composer during a turn (Stop no longer
///      replaces Send)
final _cfg = GatewayConfig(url: 'http://localhost:1');

/// Store-level fake: records calls, serves scripted responses, and lets the
/// test drive connection-state and event streams.
class R4Gateway extends GatewayClient {
  R4Gateway() : super(_cfg);
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
  int count(String m) => calls.where((c) => c.$1 == m).length;
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

  // ── Issue 1: stuck-working reconciliation ───────────────────────────

  test('lost terminal event is repaired by authoritative idle status',
      () async {
    final gw = R4Gateway();
    gw.responses['session.active_list'] = {
      'sessions': [
        {'session_id': 'live-a', 'status': 'idle'},
      ]
    };
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    // A turn is in flight locally…
    store.streamingForTest = true;
    expect(store.streaming, isTrue);

    // …but the gateway says the session is idle (the message.complete event
    // was lost). The event-driven reconcile must drop the stale flag.
    store.resetStatusPollThrottleForTest();
    await store.reconcileActiveTurnStatus();
    expect(store.streaming, isFalse,
        reason: 'gateway says idle — the stuck local flag must be dropped');
  });

  test('reconcile marks working a turn that started on another client',
      () async {
    final gw = R4Gateway();
    // Deliberately NOT pre-configured: the connect-time auto-reconcile sees
    // no live sessions and no-ops, so the assertion below is deterministic.
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    // Now the gateway reports the session as working (a turn started on
    // another client). The reconcile must reflect it.
    gw.responses['session.active_list'] = {
      'sessions': [
        {'session_id': 'live-a', 'status': 'working'},
      ]
    };
    store.resetStatusPollThrottleForTest();
    await store.reconcileActiveTurnStatus();
    expect(store.streaming, isTrue,
        reason: 'a turn running elsewhere must be reflected');
  });

  test('reconcile updates per-session dot states from the gateway', () async {
    final gw = R4Gateway();
    gw.responses['session.active_list'] = {
      'sessions': [
        {'session_id': 's-work', 'status': 'working'},
        {'session_id': 's-wait', 'status': 'waiting'},
        {'session_id': 's-idle', 'status': 'idle'},
      ]
    };
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    store.resetStatusPollThrottleForTest();
    await store.reconcileActiveTurnStatus();
    expect(store.sessionDotState('s-work'), 'working');
    expect(store.sessionDotState('s-wait'), 'needs-input');
    expect(store.sessionDotState('s-idle'), 'idle');
    expect(store.sessionDotState('s-unknown'), 'idle',
        reason: 'unknown sessions fall back to idle');
  });

  // ── Issue 4: mid-turn slash dispatch (/queue, /steer, …) ─────────────

  test('/queue is a structured send: prompt.submit carries the message',
      () async {
    final gw = R4Gateway();
    gw.responses['slash.exec'] = {
      'type': 'send',
      'message': 'focus on the tests',
      'output': '',
    };
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    final d = await store.execSlashDispatch('/queue focus on the tests');
    expect(d.type, 'send');

    // The app must ACT on the directive — the old code only read
    // res['output'] (empty) and silently did nothing.
    final submit = gw.callFor('prompt.submit');
    expect(submit, isNotNull,
        reason: '/queue must submit its message mid-turn');
    expect(submit!.$2['text'], 'focus on the tests');

    // Regression: this Dart SDK allows switch-case fallthrough without an
    // error. If the 'send' case falls into 'prefill', the queued message
    // would ALSO be stashed back into the composer and reappear as editable
    // text after /queue — so a send-type directive must never leave a
    // composer prefill behind.
    expect(store.takeComposerPrefill(), isNull,
        reason: 'a send directive must not fall through into the prefill case');
  });

  test('plain {output: …} slash result stays display-only (no submit)',
      () async {
    final gw = R4Gateway();
    gw.responses['slash.exec'] = {'output': 'help text'};
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    final d = await store.execSlashDispatch('/help');
    expect(d.type, 'exec');
    expect(d.display, 'help text');
    expect(gw.called('prompt.submit'), isFalse);
  });

  test('prefill directive stages the composer text, does not submit',
      () async {
    final gw = R4Gateway();
    gw.responses['slash.exec'] = {
      'type': 'prefill',
      'message': 'previous message',
      'output': '',
    };
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    await store.execSlashDispatch('/undo');
    expect(gw.called('prompt.submit'), isFalse);
    expect(store.takeComposerPrefill(), 'previous message');
    expect(store.takeComposerPrefill(), isNull,
        reason: 'prefill is consumed once');
  });

  test('mid-turn plain send surfaces the gateway busy status', () async {
    final gw = R4Gateway();
    // A turn is running: the gateway busy-queues the send.
    gw.responses['prompt.submit'] = {'status': 'queued'};
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    await store.send('nudge me when done');
    final submit = gw.callFor('prompt.submit');
    expect(submit, isNotNull,
        reason: 'plain text must be sendable mid-turn, not blocked');
    expect(submit!.$2['text'], 'nudge me when done');
    expect(store.statusLine, contains('Queued'));
  });

  // ── Issues 5 + 6: home screen widget behavior ───────────────────────

  testWidgets('composer keeps Send AND shows Stop during a streaming turn',
      (tester) async {
    final gw = R4Gateway();
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
    await tester.pump();

    // Idle: Send present, no Stop.
    expect(find.byTooltip('Send'), findsOneWidget);
    expect(find.byTooltip('Stop current turn'), findsNothing);

    // Turn running: Stop appears BESIDE Send — it no longer replaces it,
    // which is what made mid-turn commands impossible to send.
    store.streamingForTest = true;
    await tester.pump();
    expect(find.byTooltip('Send (queued after the current turn)'),
        findsOneWidget,
        reason: 'Send must stay available during a turn');
    expect(find.byTooltip('Stop current turn'), findsOneWidget);
    // With text in the composer both controls are live mid-turn: the user
    // can send a mid-turn nudge OR stop the run, without choosing.
    await tester.enterText(find.byType(TextField), 'mid-turn nudge');
    await tester.pump();
    final send = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded));
    expect(send.onPressed, isNotNull,
        reason: 'a mid-turn send must be possible with text ready');
    final stop = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.stop_rounded));
    expect(stop.onPressed, isNotNull,
        reason: 'the turn must be stoppable at the same time');
  });

  testWidgets('a turn switch jumps the transcript to the newest message',
      (tester) async {
    final gw = R4Gateway();
    gw.responses['session.resume'] = {
      'session_id': 'live-b',
      'resumed': 'stored-b',
      'messages': List.generate(
          40,
          (i) => {'role': 'user', 'text': 'message $i', 'ts': i.toDouble()})
    };
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
    await tester.pump();

    // Switch to another conversation; the transcript is repopulated from
    // history and the user must land on the NEWEST message, not the top.
    await store.resumeSession('stored-b');
    await tester.pumpAndSettle();
    expect(store.messages.length, 40);
    expect(find.text('message 39'), findsOneWidget,
        reason: 'the newest message must be visible after a switch');
  });

  // ── Issue 3: splash + version ───────────────────────────────────────

  testWidgets('splash shows logo, tagline and version, then fades away',
      (tester) async {
    // No saved connection: the app underneath is the ConnectionScreen, which
    // proves the splash overlays the REAL app (it never blocks it).
    final app = TalaryApp(
      model: AppModel(),
      ownsModel: true,
      showSplash: true,
    );
    await tester.pumpWidget(app);

    // During the beat: tagline and version are visible (the splash card's
    // own), the logo asset is in the tree, and the brand line is shown.
    // 'Talaria' also appears in the ConnectionScreen underneath — so we count
    // both, which also proves the splash overlays the REAL app.
    expect(find.text('Talaria'), findsNWidgets(2));
    expect(find.text(kAppTagline), findsOneWidget);
    expect(find.text(kAppVersionLabel), findsOneWidget);
    expect(find.text('The Winged Sandals of Hermes - Swift Passage, Wherever You Are.'),
        findsOneWidget);
    expect(find.byKey(const Key('talaria.splash.asset')), findsOneWidget);

    // At the 1s mark the splash is still holding (the ~3s beat), so it has
    // NOT yet faded.
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byKey(const Key('talaria.splash.asset')), findsOneWidget);

    // …and after the full ~3s hold + fade the overlay is gone from the tree.
    await tester.pump(const Duration(milliseconds: 2600));
    expect(find.byKey(const Key('talaria.splash.asset')), findsNothing);
  });

  test('version constants are well-formed and in lockstep shape', () {
    expect(kAppVersionLabel, contains(kAppVersion));
    expect(kAppVersionLabel, contains('build $kAppBuildCode'));
    expect(kAppVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
  });

  // ── Review round: resume restores what the gateway replays ──────────

  test('resume restores a parked clarify so it is answerable', () async {
    final gw = R4Gateway();
    gw.responses['session.resume'] = {
      'session_id': 'live-c',
      'resumed': 'stored-c',
      'messages': <Map<String, dynamic>>[],
      'running': false,
      // request_id is mandatory for clarify.respond (see _respond in
      // tui_gateway/server.py); without it the reply is rejected and the card
      // can never be cleared.
      'pending_clarify': {
        'request_id': 'req-c',
        'question': 'Which option?',
        'choices': ['a', 'b'],
      },
    };
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();
    await store.resumeSession('stored-c');

    // Before the fix the resume path dropped pending_clarify: the session
    // looked idle while its agent waited for an answer that had no card to
    // deliver it from.
    expect(store.pendingRequest, isNotNull,
        reason: 'a parked clarify must surface as a pending request');
    expect(store.pendingRequest!.type, 'clarify.request');
    expect(store.pendingRequest!.payload['question'], 'Which option?');
    expect(store.activeSessionState, 'needs-input');

    // …and it must be ANSWERABLE from this client.
    await store.respondApproval(approved: true, choice: 'a');
    expect(gw.called('clarify.respond'), isTrue);
    expect(store.pendingRequest, isNull);
  });

  test('resume of a still-running session reflects the live turn', () async {
    final gw = R4Gateway();
    gw.responses['session.resume'] = {
      'session_id': 'live-d',
      'resumed': 'stored-d',
      'messages': <Map<String, dynamic>>[],
      'running': true,
      'pending_approval': {'command': 'rm -rf /tmp/x'},
    };
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();
    await store.resumeSession('stored-d');

    // A resume can land on a turn that is still running (started elsewhere):
    // the spinner, Stop, and mid-turn Send must all be live, not idle.
    expect(store.streaming, isTrue,
        reason: 'a running resumed session must show as working');
    expect(store.pendingRequest, isNotNull);
    expect(store.pendingRequest!.type, 'approval.request');
    expect(store.pendingRequest!.payload['command'], 'rm -rf /tmp/x');
  });

  // ── Review round: compress targets the clicked row, not the active one ──

  test('compressSession targets the requested row, not the active conversation',
      () async {
    final gw = R4Gateway();
    // The live roster: the row for stored-b maps to runtime sid live-b.
    gw.responses['session.active_list'] = {
      'sessions': [
        {'session_id': 'live-b', 'session_key': 'stored-b', 'status': 'idle'},
      ]
    };
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect(); // active session is live-a (fresh draft)

    // Compress the stored-b row: the gateway call must carry live-b (the row's
    // runtime sid), NOT live-a (whatever is on screen). Before the fix the
    // call-site dropped the id, so this would have compressed live-a.
    final r = await store.compressSession(storedId: 'stored-b');
    expect(r, 'Compressed');
    expect(gw.callFor('session.compress')!.$2['session_id'], 'live-b',
        reason: 'the clicked row must be the compress target');

    // The no-arg path still targets the ACTIVE conversation.
    await store.compressSession();
    final compressCalls = gw.calls.where((c) => c.$1 == 'session.compress').toList();
    expect(compressCalls, hasLength(2));
    expect(compressCalls.last.$2['session_id'], 'live-a',
        reason: 'with no row id the active conversation is the target');
  });
}
