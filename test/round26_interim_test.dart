import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Text doubling around a tool call (Round 26).
///
/// Reported: "Between the end of a thinking block and the tool call block after
/// it, text responses are doubling." The transcript rendered
///
///   [Reasoning] → "Now the missing expire handling in the store:"
///   → [execute_code header] → "Now the missing expire handling in the store:"
///   → [result card]
///
/// Root cause: `ChatMessage.setText` (the authoritative write from a
/// `message.interim` seal and from `message.complete`) only replaced the text
/// when `_parts.last` happened to BE text. A `tool.start` for the action the
/// commentary introduced lands between the streamed deltas and the seal, so
/// `setText` saw a tool part last and APPENDED a second copy. The fix targets
/// the LAST TEXT part, the same thing the desktop does
/// (`mergeFinalAssistantText` replaces rather than appends).
final _cfg = GatewayConfig(url: 'http://localhost:1');

class R26Gateway extends GatewayClient {
  R26Gateway() : super(_cfg);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);

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
    switch (method) {
      case 'session.resume':
        return {
          'session_id': 'rt-1',
          'resumed': params['session_id'],
          'messages': const <Map<String, dynamic>>[],
          'info': {'model': 'test-model'},
        };
      case 'session.list':
        return {'sessions': const <Map<String, dynamic>>[]};
      case 'session.active_list':
        return {'sessions': const <Map<String, dynamic>>[]};
      default:
        return {};
    }
  }

  void emit(String type, Map<String, dynamic> data) =>
      pushed.add(GatewayEvent(type: type, sessionId: 'rt-1', payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
    await stateCtl.close();
  }
}

Future<ChatStore> _open(R26Gateway gw) async {
  final store = ChatStore(config: _cfg, client: gw);
  await store.connect();
  await store.resumeSession('stored-x');
  return store;
}

int _textParts(ChatMessage m) =>
    m.parts.where((p) => p.kind == MessagePartKind.text).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const line = 'Now the missing expire handling in the store:';

  group('an authoritative text write replaces, never appends (round 26)', () {
    test('a seal after a tool part does not duplicate the streamed segment',
        () {
      final m = ChatMessage(role: 'assistant', text: '');
      m.appendReasoning('weighing the options');
      m.appendText(line); // streamed by message.delta
      m.addTool(ToolActivity(name: 'execute_code', toolId: 't1'));
      m.setText(line); // the message.interim seal

      expect(_textParts(m), 1,
          reason: 'the seal must replace the segment, not add a second copy');
      expect(m.text, line, reason: 'exactly one copy of the line');
      expect(
        m.parts.map((p) => p.kind).toList(),
        [MessagePartKind.reasoning, MessagePartKind.text, MessagePartKind.tool],
        reason: 'the commentary stays BEFORE the tool call it introduced',
      );
    });

    test('a seal with no text part yet still adds the text', () {
      final m = ChatMessage(role: 'assistant', text: '');
      m.setText(line);
      expect(m.text, line);
      expect(_textParts(m), 1);
    });

    test('clearing text never removes a non-text part', () {
      final m = ChatMessage(role: 'assistant', text: '');
      m.appendReasoning('thought');
      m.addTool(ToolActivity(name: 'terminal', toolId: 't1'));

      m.setText('');

      expect(m.parts.length, 2,
          reason: 'an empty authoritative text must not delete the tool part');
      expect(m.parts.map((p) => p.kind).toList(),
          [MessagePartKind.reasoning, MessagePartKind.tool]);
    });
  });

  group('the streaming path renders a commentary line once (round 26)', () {
    test('delta → tool.start → interim(already_streamed) keeps one copy',
        () async {
      final gw = R26Gateway();
      final store = await _open(gw);
      addTearDown(store.dispose);

      gw.emit('message.start', const {});
      gw.emit('thinking.delta', {'text': 'checking the store'});
      gw.emit('message.delta', {'text': line});
      gw.emit('tool.start', {'name': 'execute_code', 'tool_id': 't1'});
      gw.emit('message.interim', {'text': line, 'already_streamed': true});

      final m = store.messages.last;
      expect(m.text, line,
          reason: 'the reported doubling: the line must appear once');
      expect(_textParts(m), 1);
      expect(m.parts.last.kind, MessagePartKind.tool,
          reason: 'the tool call stays last; only the text was replaced');
    });

    test('a seal whose text is already on screen adds nothing, flag or not',
        () async {
      final gw = R26Gateway();
      final store = await _open(gw);
      addTearDown(store.dispose);

      gw.emit('message.start', const {});
      gw.emit('message.delta', {'text': 'first segment.'});
      // No `already_streamed` flag at all: the prose already ends with this
      // segment, so it must not be added a second time.
      gw.emit('message.interim', {'text': 'first segment.'});

      expect(store.messages.last.text, 'first segment.');
      expect(_textParts(store.messages.last), 1);
    });

    test('a never-streamed segment is added as its own sealed bubble',
        () async {
      final gw = R26Gateway();
      final store = await _open(gw);
      addTearDown(store.dispose);

      gw.emit('message.start', const {});
      gw.emit('message.delta', {'text': 'first segment.'});
      gw.emit('message.interim',
          {'text': 'first segment.', 'already_streamed': true});
      // Commentary the client never saw stream: it must be preserved, and an
      // interim seals the bubble, so this lands as a new assistant message.
      gw.emit('message.interim',
          {'text': 'second segment.', 'already_streamed': false});

      final sealed = store.messages[store.messages.length - 2];
      expect(sealed.text, 'first segment.',
          reason: 'the earlier prose survives untouched');
      expect(store.messages.last.text, 'second segment.',
          reason: 'a never-streamed segment must be shown, not dropped');
      expect(_textParts(store.messages.last), 1);
    });

    test('message.complete after a tool part still finalizes in place',
        () async {
      final gw = R26Gateway();
      final store = await _open(gw);
      addTearDown(store.dispose);

      gw.emit('message.start', const {});
      gw.emit('message.delta', {'text': 'Working on it.'});
      gw.emit('tool.start', {'name': 'terminal', 'tool_id': 't2'});
      gw.emit('tool.complete', {'tool_id': 't2'});
      gw.emit('message.complete', {'text': 'Working on it.'});

      final m = store.messages.last;
      expect(m.text, 'Working on it.',
          reason: 'the final text must replace the streamed copy even when a '
              'tool part follows it');
      expect(_textParts(m), 1);
    });
  });
}
