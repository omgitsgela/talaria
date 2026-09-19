import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/store/chat_store.dart';
import 'package:talaria/src/widgets/attachment_strip.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/media/image_attachment.dart';

class FakeGateway extends GatewayClient {
  FakeGateway() : super(GatewayConfig(url: 'http://localhost:8080'));
  final calls = <(String, Map<String, dynamic>)>[];
  String? failMethod;
  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    calls.add((method, params));
    if (method == failMethod) throw GatewayError('injected failure');
    if (method == 'session.create') return {'session_id': 'live'};
    if (method == 'session.resume') {
      return {
        'session_id': 'live-${params['session_id']}',
        'resumed': params['session_id'],
        'messages': [
          for (var i = 0; i < 60; i++)
            {
              'role': 'user',
              'text': 'Message $i: a line in a long conversation.'
            }
        ],
      };
    }
    if (method == 'file.attach') return {'ref_text': '@file:notes.txt'};
    if (method == 'image.attach_bytes') {
      return {
        'attached': true,
        'path': '/tmp/photo.jpg',
        'count': 1,
        'bytes': base64Decode(params['content_base64'] as String).length,
        'text': '[User attached image: photo.jpg]',
        'remainder': ''
      };
    }
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'gallery and camera use the injected picker and retain local previews',
      (tester) async {
    final client = FakeGateway();
    final store = ChatStore(config: client.config, client: client);
    addTearDown(store.dispose);
    final sources = <ImageSource>[];
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
      storeOverride: store,
      imagePicker: (source) async {
        sources.add(source);
        return XFile.fromData(Uint8List.fromList([255, 216, 255]),
            path: 'picked.jpg');
      },
    )));
    await tester.tap(find.byTooltip('Attach image'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(sources, [ImageSource.gallery]);
    expect(store.attachmentDetails.single.filename, 'picked.jpg');
    await tester.tap(find.byTooltip('Take photo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(sources, [ImageSource.gallery, ImageSource.camera]);
    expect(store.pendingAttachments, hasLength(2));
    expect(client.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  test('phone images wait for send, then stage before submitting the turn',
      () async {
    final client = FakeGateway();
    final store = ChatStore(config: client.config, client: client);
    addTearDown(store.dispose);
    store.queueImage(Uint8List.fromList([255, 216, 255]),
        filename: 'phone.jpg');
    expect(client.calls, isEmpty);
    expect(store.attachmentDetails.single.filename, 'phone.jpg');
    expect(await store.send(''), isTrue);
    expect(
        client.calls.map((c) => c.$1),
        containsAllInOrder(
            ['session.create', 'image.attach_bytes', 'prompt.submit']));
    final submit = client.calls.firstWhere((c) => c.$1 == 'prompt.submit').$2;
    expect(submit, {'session_id': 'live', 'text': ''});
    expect(store.pendingAttachments, isEmpty);
    expect(store.attachmentDetails, isEmpty);
  });

  test('failed session creation preserves the draft photo without throwing',
      () async {
    final client = FakeGateway()..failMethod = 'session.create';
    final store = ChatStore(config: client.config, client: client);
    addTearDown(store.dispose);
    store.queueImage(Uint8List.fromList([255, 216, 255]),
        filename: 'phone.jpg');
    expect(await store.send('look'), isFalse);
    expect(store.attachmentDetails.single.filename, 'phone.jpg');
  });

  test('failed lifecycle detach preserves both staged and local photos',
      () async {
    final client = FakeGateway();
    final store = ChatStore(config: client.config, client: client);
    addTearDown(store.dispose);
    await store.attachImageBytes([255, 216, 255], filename: 'staged.jpg');
    store.queueImage(Uint8List.fromList([255, 216, 255]),
        filename: 'local.jpg');
    client.failMethod = 'image.detach';
    expect(await store.resumeSession('other'), isFalse);
    expect(store.attachmentDetails.map((e) => e.filename),
        ['staged.jpg', 'local.jpg']);
  });

  testWidgets(
      'adding and removing photos does not reset a real transcript drag',
      (tester) async {
    final client = FakeGateway();
    final store = ChatStore(config: client.config, client: client);
    addTearDown(store.dispose);
    await store.resumeSession('history');
    await tester
        .pumpWidget(MaterialApp(home: HomeScreen(storeOverride: store)));
    await tester.pump();
    final transcript =
        find.byWidgetPredicate((w) => w is ListView && w.reverse);
    expect(transcript, findsOneWidget);
    await tester.drag(transcript, const Offset(0, 350));
    await tester.pumpAndSettle();
    final controller = tester.widget<ListView>(transcript).controller!;
    expect(controller.offset, greaterThan(48));
    store.queueImage(Uint8List.fromList([255, 216, 255]),
        filename: 'phone.jpg');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(controller.offset, greaterThan(48));
    expect(tester.widget<ListView>(transcript).controller, same(controller));
    await tester.tap(find.byTooltip('Remove phone.jpg'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(controller.offset, greaterThan(48));
    expect(store.pendingAttachments, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('failed staging retains the photo and never submits a partial turn',
      () async {
    final client = FakeGateway()..failMethod = 'image.attach_bytes';
    final store = ChatStore(config: client.config, client: client);
    addTearDown(store.dispose);
    store.queueImage(Uint8List.fromList([255, 216, 255]),
        filename: 'phone.jpg');
    expect(await store.send('look'), isFalse);
    expect(store.attachmentDetails.single.filename, 'phone.jpg');
    expect(client.calls.where((c) => c.$1 == 'prompt.submit'), isEmpty);
    expect(store.messages, isEmpty);
    client.failMethod = null;
    expect(await store.send('look'), isTrue);
    expect(store.pendingAttachments, isEmpty);
  });

  test('failed submit retries the staged photo without uploading it twice',
      () async {
    final client = FakeGateway()..failMethod = 'prompt.submit';
    final store = ChatStore(config: client.config, client: client);
    addTearDown(store.dispose);
    store.queueImage(Uint8List.fromList([255, 216, 255]),
        filename: 'phone.jpg');
    expect(await store.send('look'), isFalse);
    expect(store.pendingAttachments, ['/tmp/photo.jpg']);
    client.failMethod = null;
    expect(await store.send('look'), isTrue);
    expect(
        client.calls.where((c) => c.$1 == 'image.attach_bytes'), hasLength(1));
  });

  test('files still use file.attach and join a photo in the submitted turn',
      () async {
    final client = FakeGateway();
    final store = ChatStore(config: client.config, client: client);
    addTearDown(store.dispose);
    await store.attachFileBytes([65], name: 'notes.txt');
    store.queueImage(Uint8List.fromList([255, 216, 255]),
        filename: 'phone.jpg');
    expect(await store.send('compare'), isTrue);
    final file = client.calls.firstWhere((c) => c.$1 == 'file.attach').$2;
    expect(base64Decode((file['data_url'] as String).split(',').last), [65]);
    expect(client.calls.firstWhere((c) => c.$1 == 'prompt.submit').$2['text'],
        '@file:notes.txt compare');
  });

  test('removing an unstaged photo performs no RPC', () async {
    final client = FakeGateway();
    final store = ChatStore(config: client.config, client: client);
    addTearDown(store.dispose);
    store.queueImage(Uint8List.fromList([255, 216, 255]),
        filename: 'phone.jpg');
    await store.detachAttachment(store.pendingAttachments.single);
    expect(store.pendingAttachments, isEmpty);
    expect(client.calls, isEmpty);
  });

  test('removing a staged image detaches its gateway path', () async {
    final client = FakeGateway();
    final store = ChatStore(config: client.config, client: client);
    addTearDown(store.dispose);
    final ref =
        await store.attachImageBytes([255, 216, 255], filename: 'phone.jpg');
    expect(store.attachmentDetails.single.sizeBytes, 3);
    await store.detachAttachment(ref);
    expect(client.calls.last.$1, 'image.detach');
    expect(client.calls.last.$2, {'session_id': 'live', 'path': ref});
    expect(store.attachmentDetails, isEmpty);
  });

  testWidgets(
      'strip displays a thumbnail, filename and size and removes the entry',
      (tester) async {
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=');
    final entries = [
      PendingAttachment(
          ref: 'local',
          filename: 'phone.png',
          sizeBytes: bytes.length,
          bytes: bytes)
    ];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
      builder: (context, setState) => AttachmentStrip(
          attachments: entries,
          onRemove: (ref) =>
              setState(() => entries.removeWhere((e) => e.ref == ref))),
    ))));
    expect(find.text('phone.png'), findsOneWidget);
    expect(find.text('${bytes.length} B'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.byTooltip('Remove phone.png'));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(tester.getSize(find.byType(AttachmentStrip)).height, 0);
  });
  test('refuses images over the 25 MiB gateway cap without an RPC', () async {
    final client = FakeGateway();
    final service = ImageAttachmentService(client, sessionId: 'live');
    await expectLater(
      service.attach(Uint8List(25 * 1024 * 1024 + 1), filename: 'large.jpg'),
      throwsA(isA<GatewayError>()
          .having((e) => e.message, 'message', contains('25 MiB'))),
    );
    expect(client.calls, isEmpty);
    await client.dispose();
  });
  test('encodes bytes and preserves the gateway result metadata', () async {
    final client = FakeGateway();
    final service = ImageAttachmentService(client, sessionId: 'live');
    final bytes = Uint8List.fromList([255, 216, 255, 1]);
    final result = await service.attach(bytes, filename: 'photo.jpg');
    expect(client.calls.single.$1, 'image.attach_bytes');
    final params = client.calls.single.$2;
    expect(params.keys,
        unorderedEquals(['session_id', 'content_base64', 'filename']));
    expect(params['session_id'], 'live');
    expect(params['filename'], 'photo.jpg');
    expect(base64Decode(params['content_base64'] as String), bytes);
    expect(result.path, '/tmp/photo.jpg');
    expect(result.count, 1);
    expect(result.metadata['bytes'], bytes.length);
    expect(result.metadata['text'], contains('photo.jpg'));
    await client.dispose();
  });
}
