import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/store/chat_store.dart';

final config = GatewayConfig(url: 'http://localhost:1');

class ChatGateway extends GatewayClient {
  ChatGateway() : super(config);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? handle;

  @override
  GwConnectionState get state => GwConnectionState.open;

  @override
  Stream<GatewayEvent> get events => pushed.stream;

  @override
  Stream<GwConnectionState> get stateChanges => const Stream.empty();

  @override
  Future<void> connect({bool isReconnect = false}) async {}

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    calls.add((method, params));
    if (handle != null) return handle!(method, params);
    return switch (method) {
      'session.list' => {'sessions': []},
      'session.most_recent' => {'session_id': null},
      'session.resume' => {
          'session_id': 'live-${params['session_id']}',
          'resumed': params['session_id'],
          'messages': [
            {'role': 'user', 'text': 'stored question'},
            {'role': 'assistant', 'text': 'stored answer'}
          ],
          'info': {'model': 'test-model'}
        },
      _ => {},
    };
  }

  void emit(String type, Map<String, dynamic> data, {String sid = 'live-a'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('resume uses returned live identity and gateway text history', () async {
    final gw = ChatGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');
    expect(store.activeSessionId, 'live-a');
    expect(store.activeStoredSessionId, 'a');
    expect(store.messages.map((m) => m.text),
        ['stored question', 'stored answer']);
    expect(store.currentModel, 'test-model');
  });

  test('late resume cannot overwrite newer selection', () async {
    final gw = ChatGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    final a = Completer<Map<String, dynamic>>();
    final b = Completer<Map<String, dynamic>>();
    gw.handle = (m, p) => p['session_id'] == 'a' ? a.future : b.future;
    final first = store.resumeSession('a');
    final second = store.resumeSession('b');
    b.complete({
      'session_id': 'live-b',
      'resumed': 'b',
      'messages': [
        {'role': 'user', 'text': 'B'}
      ]
    });
    await second;
    a.complete({
      'session_id': 'live-a',
      'resumed': 'a',
      'messages': [
        {'role': 'user', 'text': 'A'}
      ]
    });
    await first;
    gw.emit('message.delta', {'text': 'wrong'});
    expect(store.activeSessionId, 'live-b');
    expect(store.messages.map((m) => m.text), ['B']);
  });

  test('assistant tool collections are independent per message', () {
    final a = ChatMessage(role: 'assistant');
    final b = ChatMessage(role: 'assistant');
    a.addTool(ToolActivity(name: 'terminal'));
    expect(a.tools, hasLength(1));
    expect(b.tools, isEmpty);
  });

  test(
      'message.interim with already_streamed seals segment without duplicating text',
      () async {
    final gw = ChatGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');

    gw.emit('message.start', {});
    gw.emit('message.delta', {'text': 'Hello'});
    expect(store.messages.last.text, 'Hello');
    expect(store.messages.last.pending, isTrue);

    // already_streamed=true means the text was already streamed; seal the segment
    gw.emit('message.interim', {
      'text': 'Hello world',
      'already_streamed': true,
    });
    // The sealed message should have the authoritative text but not append
    expect(store.messages.last.text, 'Hello world');
    expect(store.messages.last.pending, isFalse);

    // New segment starts on next delta
    gw.emit('message.delta', {'text': 'Continued'});
    expect(store.messages.last.text, 'Continued');
    expect(store.messages.last.pending, isTrue);

    gw.emit('message.complete', {'text': 'Continued'});
    expect(store.messages.last.pending, isFalse);
    expect(store.messages.last.text, 'Continued');
  });

  test('tool.start reads context as preview, tool.complete correlates by tool_id',
      () async {
    final gw = ChatGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');

    gw.emit('message.start', {});
    gw.emit('tool.start', {
      'name': 'terminal',
      'tool_id': 'one',
      'context': 'ls -la',
    });
    gw.emit('tool.start', {
      'name': 'web_search',
      'tool_id': 'two',
      'context': 'search query',
    });

    final tools = store.messages.expand((m) => m.tools).toList();
    expect(tools, hasLength(2));
    expect(tools[0].name, 'terminal');
    expect(tools[0].preview, 'ls -la');
    expect(tools[1].name, 'web_search');

    // Complete the FIRST tool (not the last one)
    gw.emit('tool.complete', {
      'name': 'terminal',
      'tool_id': 'one',
      'summary': 'done first',
      'result': {'exit_code': 0},
    });
    expect(tools[0].state, ToolState.done);
    expect(tools[0].summary, 'done first');
    expect(tools[1].state, ToolState.running);

    gw.emit('tool.complete', {
      'name': 'web_search',
      'tool_id': 'two',
      'error': 'timeout after 30s',
    });
    expect(tools[1].state, ToolState.error);

    gw.emit('message.complete', {'text': 'Final'});
    expect(store.messages.any((m) => m.pending), isFalse);
  });

  test('approval.respond sends choice param, clarify.respond sends answer param',
      () async {
    final gw = ChatGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');

    // Simulate approval request. `request_id` is mandatory: the gateway
    // resolves the pending request by it (`_respond` / approval queue).
    store.pendingRequest = GatewayEvent(
      type: 'approval.request',
      sessionId: 'live-a',
      payload: {'request_id': 'req-a1', 'command': 'rm -rf /'},
    );
    await store.respondApproval(approved: true);
    final lastApproval = gw.calls.last;
    expect(lastApproval.$1, 'approval.respond');
    expect(lastApproval.$2['request_id'], 'req-a1');
    // The advertised choice set is once|session|always|deny.
    expect(lastApproval.$2['choice'], 'once');

    // Simulate clarify request
    store.pendingRequest = GatewayEvent(
      type: 'clarify.request',
      sessionId: 'live-a',
      payload: {'request_id': 'req-c1', 'question': 'Which file?'},
    );
    await store.respondApproval(approved: true, choice: 'file_a.dart');
    final lastClarify = gw.calls.last;
    expect(lastClarify.$1, 'clarify.respond');
    expect(lastClarify.$2['request_id'], 'req-c1');
    expect(lastClarify.$2['answer'], 'file_a.dart');
  });

  test('approval.respond failure restores the pending card and surfaces the error',
      () async {
    final gw = ChatGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');

    // Simulate the approval.reply never reaching the gateway (e.g. socket drop).
    gw.handle = (m, p) async {
      if (m == 'approval.respond') throw Exception('socket closed');
      return <String, dynamic>{};
    };

    store.pendingRequest = GatewayEvent(
      type: 'approval.request',
      sessionId: 'live-a',
      payload: {'request_id': 'req-a2', 'command': 'rm -rf /'},
    );
    await store.respondApproval(approved: true);

    // The card must come back so the user can retry, and the failure is visible
    // rather than silently swallowed (which would make an unsent approval look
    // confirmed).
    expect(store.pendingRequest, isNotNull);
    expect(store.pendingRequest!.type, 'approval.request');
    expect(store.statusLine, contains('not sent'));
  });

  test('loadModels parses providers/models from real gateway payload', () async {
    final gw = ChatGateway();
    gw.handle = (m, p) async => {
      'model': 'openai/gpt-4o',
      'provider': 'openai',
      'providers': [
        {
          'slug': 'openai',
          'name': 'OpenAI',
          'is_current': true,
          'authenticated': true,
          'models': ['gpt-4o', 'gpt-4o-mini']
        },
        {
          'slug': 'anthropic',
          'name': 'Anthropic',
          'authenticated': false,
          'models': [
            {'slug': 'claude-3.5-sonnet', 'id': 'claude-3.5-sonnet'}
          ]
        }
      ]
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.loadModels();
    expect(store.models.length, 3);
    expect(store.models[0].slug, 'gpt-4o');
    expect(store.models[0].provider, 'openai');
    expect(store.models[0].isCurrent, isTrue,
        reason: 'gpt-4o matches the top-level current model');
    expect(store.models[1].slug, 'gpt-4o-mini');
    expect(store.models[1].isCurrent, isFalse,
        reason: 'gpt-4o-mini shares the provider but is not the current model');
    expect(store.models[2].slug, 'claude-3.5-sonnet');
    expect(store.models[2].authenticated, isFalse);
  });

  test('loadProfiles parses from real gateway payload', () async {
    final gw = ChatGateway();
    gw.handle = (m, p) async => {
      'profiles': [
        {
          'name': 'default',
          'is_default': true,
          'model': 'gpt-4o',
          'provider': 'openai',
          'description': 'Default profile'
        },
        {
          'name': 'work',
          'is_default': false,
          'description': 'Work profile'
        }
      ]
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.loadProfiles();
    expect(store.profiles.length, 2);
    expect(store.profiles[0].name, 'default');
    expect(store.profiles[0].isDefault, isTrue);
    expect(store.profiles[1].name, 'work');
    expect(store.profiles[1].isDefault, isFalse);
  });
}
