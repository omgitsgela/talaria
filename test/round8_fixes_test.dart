import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 8 (2026-09-11) regressions — scroll, model quick-config, and
/// thinking traces:
///   1. thinking traces: streamed live, preserved across history refresh +
///      resume, and governed by the show/hide DISPLAY switch (the gateway's
///      `reasoning` display word), which the old app had no write path for
///   2. model quick-config RPCs: `config.set reasoning <level>` (session) and
///      `config.set fast fast|normal`
///   3. sticky open-jump: a conversation (re)open arms the jump and the view
///      lands on the newest message even after async hydration
final _cfg = GatewayConfig(url: 'http://localhost:1');

class R8Gateway extends GatewayClient {
  R8Gateway() : super(_cfg);
  final calls = <(String, Map<String, dynamic>)>[];
  /// method -> response; `config.get` is routed by (method, key).
  final responses = <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> configGets = {};
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
    if (method == 'config.get') {
      final key = params['key']?.toString() ?? '';
      final canned = configGets[key];
      if (canned != null) return canned;
    }
    if (responses.containsKey(method)) return responses[method]!;
    return switch (method) {
      'session.create' => {'session_id': 'live-a'},
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'prompt.submit' => {'status': 'streaming'},
      'config.set' => {'key': params['key'], 'value': params['value']},
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

  // ── 1. Thinking traces ───────────────────────────────────────────

  test('streamed reasoning lands on the assistant tail, visible by default',
      () async {
    final gw = R8Gateway();
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    expect(store.showReasoning, isTrue,
        reason: 'default is show — traces render until the user hides them');

    gw.emit('message.start', {});
    gw.emit('thinking.delta', {'text': 'Let me reason about this…'});

    expect(store.messages.length, 1);
    final m = store.messages.single;
    expect(m.reasoning, 'Let me reason about this…');
    expect(m.effectiveReasoning, 'Let me reason about this…',
        reason: 'visible when showReasoning is true');
  });

  test('hiding traces blanks the display, preserves the raw text, re-shows',
      () async {
    final gw = R8Gateway();
    gw.configGets['reasoning'] = {'value': 'medium', 'display': 'hide'};
    gw.configGets['fast'] = {'value': 'normal'};
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    gw.emit('message.start', {});
    gw.emit('reasoning.delta', {'text': 'traced thought'});

    // Hide: the gateway word 'hide' is what the app must honor.
    await store.setReasoningDisplay(false);
    expect(store.showReasoning, isFalse);
    expect(gw.callFor('config.set')!.$2,
        {'key': 'reasoning', 'value': 'hide', 'session_id': 'live-a'},
        reason: 'the app must write the gateway display switch');
    expect(store.messages.single.effectiveReasoning, '',
        reason: 'hidden: nothing renders');
    expect(store.messages.single.reasoning, 'traced thought',
        reason: 'display-only: the raw trace must survive');

    // Re-show: the same trace comes back without re-fetching.
    gw.configGets['reasoning'] = {'value': 'medium', 'display': 'show'};
    await store.setReasoningDisplay(true);
    expect(store.showReasoning, isTrue);
    expect(store.messages.single.effectiveReasoning, 'traced thought');
  });

  test('a sessions.changed history refresh preserves reasoning traces',
      () async {
    final gw = R8Gateway();
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    gw.emit('message.start', {});
    gw.emit('thinking.delta', {'text': 'fresh trace'});
    gw.emit('message.delta', {'text': 'the answer'});
    gw.emit('message.complete', {'text': 'the answer'});
    expect(store.messages.last.reasoning, 'fresh trace');
    expect(store.streaming, isFalse,
        reason: 'the turn is done, so the history pull is allowed');

    // The gateway's change broadcast triggers the 750ms debounced history
    // pull; the mapper must carry `reasoning` through or the trace vanishes
    // on every background refresh.
    gw.emit('sessions.changed', {});
    gw.responses['session.history'] = {
      'messages': [
        {'role': 'user', 'text': 'q'},
        {'role': 'assistant', 'text': 'the answer', 'reasoning': 'fresh trace'},
      ]
    };
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    final trace = store.messages
        .where((m) => m.reasoning.isNotEmpty)
        .toList();
    expect(trace, hasLength(1),
        reason: 'the trace must survive the history refresh');
    expect(trace.single.reasoning, 'fresh trace');
    expect(trace.single.effectiveReasoning, 'fresh trace',
        reason: 'and still render, since show is on');
  });

  test('resume hydration carries traces and the session reasoning effort',
      () async {
    final gw = R8Gateway();
    gw.responses['session.resume'] = {
      'session_id': 'live-r',
      'resumed': 'stored-r',
      'running': false,
      'info': {'model': 'grok-4.20', 'reasoning_effort': 'high'},
      'messages': [
        {'role': 'user', 'text': 'q'},
        {'role': 'assistant', 'text': 'a', 'reasoning': 'resumed trace'},
      ],
    };
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();
    await store.resumeSession('stored-r');

    expect(store.messages.any((m) => m.reasoning == 'resumed trace'), isTrue,
        reason: 'history traces must not be dropped on resume');
    expect(store.reasoningEffort, 'high',
        reason: 'the resumed session\'s thinking level must be restored');
    expect(store.pendingJumpToBottom, isTrue,
        reason: 'a resume is a reopen — the jump flag must be armed');
  });

  // ── 2. Model quick-config RPCs ───────────────────────────────────

  test('setReasoning is session-scoped and mirrors the effort locally',
      () async {
    final gw = R8Gateway();
    gw.configGets['reasoning'] = {'value': 'high', 'display': 'show'};
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    await store.setReasoning('high');
    final set = gw.callFor('config.set');
    expect(set!.$2['key'], 'reasoning');
    expect(set.$2['value'], 'high');
    expect(set.$2['session_id'], 'live-a',
        reason: 'quick-config edits are session-scoped, never global');
    expect(store.reasoningEffort, 'high');
    expect(store.thinkingEnabled, isTrue);
  });

  test('setFast normalizes to the gateway fast/normal vocabulary', () async {
    final gw = R8Gateway();
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    await store.setFast(true);
    expect(gw.callFor('config.set')!.$2['value'], 'fast');
    expect(store.fastEnabled, isTrue,
        reason: 'fastEnabled compares against the gateway\'s own word');

    await store.setFast(false);
    expect(gw.callFor('config.set')!.$2['value'], 'normal');
    expect(store.fastEnabled, isFalse);
  });

  // ── 3. Sticky open-jump ──────────────────────────────────────────

  testWidgets('reopening a conversation lands on the newest message',
      (tester) async {
    final gw = R8Gateway();
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

    // Reopening (resume) hydrates the transcript in a LATER notification than
    // the one that flips the session id — the jump must be sticky and retry
    // until the list has scrollable content.
    await store.resumeSession('stored-b');
    await tester.pumpAndSettle();
    expect(store.messages.length, 40);
    expect(find.text('message 39'), findsOneWidget,
        reason: 'the newest message must be visible after the open-jump');
    expect(store.pendingJumpToBottom, isFalse,
        reason: 'the jump flag is consumed once the landing succeeds');
  });

  // ── 4. Model-level display gating ────────────────────────────────

  test('ChatMessage seeds effectiveReasoning from the raw trace', () {
    final m = ChatMessage(role: 'assistant', text: 'a', reasoning: 'trace');
    expect(m.effectiveReasoning, 'trace',
        reason: 'a fresh message shows its trace until told otherwise');
  });
}
