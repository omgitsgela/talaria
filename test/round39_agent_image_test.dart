import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/store/chat_store.dart';
import 'package:talaria/src/widgets/message_bubble.dart';

final config = GatewayConfig(url: 'http://localhost:1');

/// Minimal gateway: no socket, events pushed by the test.
class ToolGateway extends GatewayClient {
  ToolGateway() : super(config);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);

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
    return switch (method) {
      'session.resume' => {
          'session_id': 'live-${params['session_id']}',
          'resumed': params['session_id'],
          'messages': const [],
          'info': {'model': 'test-model'},
        },
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data, {String sid = 'live-a'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
  }
}

Future<void> showAssistant(WidgetTester tester, List<ToolActivity> tools) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
        body: ListView(children: [
      MessageBubble(
          message: ChatMessage(role: 'assistant', text: 'Here it is.', tools: tools),
          isUser: false),
      const SizedBox(height: 1200),
    ])),
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fetchable image sources in a tool result', () {
    test('an image URL is kept', () {
      expect(
          fetchableImageSources(
              {'success': true, 'image': 'https://cdn.example/a.png'}),
          ['https://cdn.example/a.png']);
    });

    test('an images list is walked', () {
      final result = {
        'images': [
          {'url': 'https://cdn.example/b.jpg'},
          {'url': 'https://cdn.example/c.webp'},
        ]
      };
      expect(fetchableImageSources(result),
          ['https://cdn.example/b.jpg', 'https://cdn.example/c.webp']);
    });

    test('a data URL is kept', () {
      expect(fetchableImageSources({'image': 'data:image/png;base64,AAAA'}),
          ['data:image/png;base64,AAAA']);
    });

    test('a nested result is searched', () {
      expect(
          fetchableImageSources({
            'result': {'url': 'https://cdn.example/d.gif'}
          }),
          ['https://cdn.example/d.gif']);
    });

    test('a server-side path is refused', () {
      // A phone cannot fetch this, so keeping it would promise an image that
      // can never render.
      expect(
          fetchableImageSources({
            'image': '/home/someone/.hermes/images/a.png'
          }),
          isEmpty);
    });

    test('a link that is not an image is refused', () {
      expect(fetchableImageSources({'url': 'https://example.com/page.html'}),
          isEmpty);
      expect(fetchableImageSources({'success': true}), isEmpty);
      expect(fetchableImageSources(null), isEmpty);
    });
  });

  group('the store keeps a produced image', () {
    test('a tool result naming an image records it', () async {
      final gw = ToolGateway();
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      gw.emit('message.start', {});
      gw.emit('tool.start',
          {'name': 'image_generate', 'tool_id': 'img', 'context': 'a red panda'});
      gw.emit('tool.complete', {
        'tool_id': 'img',
        'summary': 'Generated 1 image',
        'result': {'success': true, 'image': 'https://cdn.example/panda.png'},
      });

      final tool = store.messages.expand((m) => m.tools).single;
      expect(tool.state, ToolState.done);
      expect(tool.images, ['https://cdn.example/panda.png']);
    });

    test('a result with only a server path records nothing', () async {
      final gw = ToolGateway();
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      gw.emit('message.start', {});
      gw.emit('tool.start', {'name': 'image_generate', 'tool_id': 'img'});
      gw.emit('tool.complete', {
        'tool_id': 'img',
        'result': {'image': '/home/someone/.hermes/images/panda.png'},
      });

      final tool = store.messages.expand((m) => m.tools).single;
      expect(tool.images, isEmpty);
    });
  });

  group('the transcript shows it', () {
    testWidgets('a tool row renders the image its result named',
        (tester) async {
      await showAssistant(tester, [
        ToolActivity(
            name: 'image_generate',
            state: ToolState.done,
            images: const ['https://cdn.example/panda.png']),
      ]);
      expect(find.byType(Image), findsOneWidget);
      // The row label; the placeholder for the un-loaded network image also
      // mentions the tool, so this must be an exact match.
      expect(find.text('image_generate'), findsOneWidget);
    });

    testWidgets('a tool with no image renders none', (tester) async {
      await showAssistant(tester, [
        ToolActivity(name: 'terminal', state: ToolState.done),
      ]);
      expect(find.byType(Image), findsNothing);
      expect(find.byType(MessageBubble), findsOneWidget);
    });
  });
}
