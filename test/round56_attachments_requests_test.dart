import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/media/attachment_cache.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/store/chat_store.dart';
import 'package:talaria/src/widgets/message_bubble.dart';

/// Round 56 (1.3.16): two open tracker items.
///
///   1. #33 - an attached image left no trace in the conversation view. The
///      refs lived only inside the message text (images were not even there),
///      and the user bubble renders text only. Fix: refs become part of
///      ChatMessage (the store carries them on its optimistic row; the
///      hydrators parse them out of the gateway's persisted text), and the
///      bubble renders a thumbnail or a file chip for each.
///   2. #31 remainder - a second sudo/secret prompt replaced the first
///      unconditionally; the replaced request was never answered and its
///      agent waited out the gateway timeout. Fix: a queue, answered in
///      order, plus `request.cancel` handling (verified against the gateway
///      source: `approval.respond`/`clarify.respond` are RPCs, NEVER events -
///      the withdrawal event is `request.cancel`, server_requests.py
///      `_emit_cancel`), and resume re-arming the gateway's `open_requests`
///      snapshot (server.py `_resume_response`: unanswered requests replay so
///      a reconnecting client can answer them).

final _cfg = GatewayConfig(url: 'http://localhost:1');

class R56Gateway extends GatewayClient {
  R56Gateway() : super(_cfg);
  final _events = StreamController<GatewayEvent>.broadcast(sync: true);
  final _requests = StreamController<ServerRequest>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];
  final replies = <Map<String, dynamic>>[];

  /// Extra fields merged into the session.resume reply (open_requests tests).
  Map<String, dynamic> resumeExtras = const {};

  /// Rows returned by session.history.
  List<Map<String, dynamic>> historyMessages = const [];

  /// When non-null, the next `clarify.respond`/`approval.respond` call throws
  /// a GatewayError with this code (transport-failure paths).
  int? failNextRespondWith;

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
    calls.add((method, params));
    return switch (method) {
      'session.resume' => {
          'session_id': 'live-x',
          'resumed': params['session_id'],
          ...resumeExtras,
        },
      'session.create' => {'session_id': 'new-sid'},
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'session.active_list' => {'sessions': const <Map<String, dynamic>>[]},
      'session.history' => {'messages': historyMessages},
      'prompt.submit' => {'status': 'streaming'},
      'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/sess/upload_1.png',
          'count': 1,
        },
      'file.attach' => {
          'attached': true,
          'name': 'notes.md',
          'path': '/tmp/sess/notes.md',
          'ref_text': '@file:notes.md',
        },
      _ => <String, dynamic>{},
    };
  }

  void pushEvent(GatewayEvent ev) => _events.add(ev);
  void pushRequest(ServerRequest req) => _requests.add(req);

  @override
  Future<void> dispose() async {
    await _events.close();
    await _requests.close();
  }
}

ChatStore fresh(R56Gateway gw) => ChatStore(config: _cfg, client: gw);

// A real 1x1 PNG: MemoryImage must decode without tripping the error builder.
final Uint8List _pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AttachmentCache.clear);
  tearDown(MessageBubble.resetTestBuildCounts);

  // ── #33a. Ref extraction (the gateway's persisted form) ─────────────
  group('ChatMessage.extractAttachmentRefs', () {
    test('trailing @image lines become refs and leave the caption', () {
      final r = ChatMessage.extractAttachmentRefs(
          'look at this\n@image:/tmp/sess/upload_1.png');
      expect(r.text, 'look at this');
      expect(r.refs, ['@image:/tmp/sess/upload_1.png']);
    });

    test('multiple trailing refs are all carried, in order', () {
      final r = ChatMessage.extractAttachmentRefs(
          'two pics\n@image:/a/one.png\n@image:/a/two.png');
      expect(r.text, 'two pics');
      expect(r.refs, ['@image:/a/one.png', '@image:/a/two.png']);
    });

    test('quoted refs (values with spaces) unwrap', () {
      final r = ChatMessage.extractAttachmentRefs(
          'photo\n@image:`/tmp/my photo.png`');
      expect(r.text, 'photo');
      expect(r.refs, ['@image:`/tmp/my photo.png`']);
      expect(ChatMessage.unwrapAttachmentRef(r.refs.single), '/tmp/my photo.png');
    });

    test('leading @file tokens (the store prepend form) are extracted', () {
      final r = ChatMessage.extractAttachmentRefs('@file:notes.md summarize');
      expect(r.text, 'summarize');
      expect(r.refs, ['@file:notes.md']);
    });

    test('a token-shaped word mid-sentence stays plain text', () {
      // The gateway persists refs only as whole trailing lines or leading
      // tokens; a mention inside prose must not become a phantom chip.
      final r = ChatMessage.extractAttachmentRefs(
          'the log mentions @file:ghost.txt in the body');
      expect(r.text, 'the log mentions @file:ghost.txt in the body');
      expect(r.refs, isEmpty);
    });

    test('plain text without refs is untouched', () {
      final r = ChatMessage.extractAttachmentRefs('hello there');
      expect(r.text, 'hello there');
      expect(r.refs, isEmpty);
    });
  });

  // ── #33b. The store carries refs on the message ─────────────────────
  group('attachment refs on the transcript (store)', () {
    test('hydrating a persisted image message carries its ref', () async {
      final gw = R56Gateway();
      gw.resumeExtras = {
        'messages': [
          {'role': 'user', 'text': 'look\n@image:/tmp/sess/upload_1.png'},
          {'role': 'assistant', 'text': 'I see it'},
        ],
      };
      final store = fresh(gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      expect(store.messages.length, 2);
      expect(store.messages.first.attachments,
          ['@image:/tmp/sess/upload_1.png']);
      expect(store.messages.first.text, 'look',
          reason: 'the ref token must not render as raw text in the bubble');
      expect(store.messages.last.attachments, isEmpty);
    });

    test('a history refresh carries refs too', () async {
      final gw = R56Gateway();
      gw.historyMessages = [
        {'role': 'user', 'text': 'see\n@image:/tmp/sess/b.png'},
      ];
      final store = fresh(gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      // sessions.changed triggers the debounced read-only history pull.
      gw.pushEvent(const GatewayEvent(type: 'sessions.changed', payload: {}));
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(store.messages.single.attachments, ['@image:/tmp/sess/b.png']);
      expect(store.messages.single.text, 'see');
    });

    test('an image-only message survives hydration (no caption)', () async {
      final gw = R56Gateway();
      gw.resumeExtras = {
        'messages': [
          {'role': 'user', 'text': '@image:/tmp/sess/lone.png'},
        ],
      };
      final store = fresh(gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      expect(store.messages.length, 1,
          reason: 'the old drop gate (empty text AND empty reasoning) would '
              'discard a caption-less image row once its refs are extracted');
      expect(store.messages.single.attachments, ['@image:/tmp/sess/lone.png']);
    });

    test('an optimistic send carries its image refs on the message', () async {
      final gw = R56Gateway();
      final store = fresh(gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      store.queueImage(_pngBytes, filename: 'shot.png');
      await store.send('what is this');

      final userRow = store.messages.first;
      expect(userRow.role, 'user');
      expect(userRow.attachments, contains('@image:/tmp/sess/upload_1.png'),
          reason: 'the sent image must leave a trace on the message itself, '
              'not only as text (issue #33)');
      expect(userRow.text, 'what is this',
          reason: 'the bubble must not display raw ref tokens');

      // The gateway must still receive the text it was getting before.
      final submit = gw.calls.firstWhere((c) => c.$1 == 'prompt.submit');
      expect(submit.$2['text'], contains('what is this'));
    });

    test('file refs ride the submitted text AND the message', () async {
      final gw = R56Gateway();
      final store = fresh(gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachFileBytes([0x48, 0x69], name: 'notes.md');
      await store.send('summarize');

      final submit = gw.calls.firstWhere((c) => c.$1 == 'prompt.submit');
      expect(submit.$2['text'], contains('@file:notes.md'),
          reason: 'the agent must still receive the ref (unchanged behavior)');

      final userRow = store.messages.first;
      expect(userRow.attachments, contains('@file:notes.md'));
      expect(userRow.text, 'summarize',
          reason: 'the token renders as a chip, not as raw text');
    });
  });

  // ── #33c. The bubble renders its attachments ────────────────────────
  group('user bubble shows its attachments', () {
    testWidgets('an image ref with cached bytes renders an Image',
        (tester) async {
      AttachmentCache.put('/tmp/sess/upload_1.png', _pngBytes);
      final msg = ChatMessage(
          role: 'user',
          text: 'look',
          attachments: const ['@image:/tmp/sess/upload_1.png']);
      await tester.pumpWidget(MaterialApp(
        home: MessageBubble(message: msg, isUser: true),
      ));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('Image unavailable'), findsNothing);
      expect(find.textContaining('@image:'), findsNothing,
          reason: 'the token is replaced by the thumbnail, not shown raw');
    });

    testWidgets('a file ref renders a chip naming the file', (tester) async {
      final msg = ChatMessage(
          role: 'user',
          text: 'summarize',
          attachments: const ['@file:notes.md']);
      await tester.pumpWidget(MaterialApp(
        home: MessageBubble(message: msg, isUser: true),
      ));
      await tester.pump();
      expect(find.text('notes.md'), findsOneWidget);
      expect(find.textContaining('@file:'), findsNothing);
    });
  });

  // ── #31. Value prompts queue instead of replacing ───────────────────
  group('concurrent sudo/secret prompts (issue #31 remainder)', () {
    test('two prompts queue and are answered in order', () async {
      final gw = R56Gateway();
      final store = fresh(gw);
      addTearDown(store.dispose);

      gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
        'id': 'srq-11',
        'method': 'sudo',
        'params': {
          'session_id': 'live-x',
          'command': 'sudo systemctl restart a',
        },
      })!);
      gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
        'id': 'srq-12',
        'method': 'secret',
        'params': {
          'session_id': 'live-x',
          'env_var': 'API_KEY',
          'prompt': 'Paste',
        },
      })!);
      await Future<void>.delayed(Duration.zero);

      // The head is shown; the second is NOT discarded. It used to be
      // overwritten unconditionally, leaving its agent parked until timeout.
      expect(store.pendingValueRequest?.id, 'srq-11');
      expect(store.pendingValueRequests.length, 2);

      store.respondValue('pw', requestId: 'srq-11');
      expect(gw.replies.first['id'], 'srq-11');
      expect((gw.replies.first['result'] as Map)['value'], 'pw');

      // Answering the head surfaces the next one, in arrival order.
      expect(store.pendingValueRequest?.id, 'srq-12');
      store.respondValue('the-key', requestId: 'srq-12');
      expect(gw.replies.last['id'], 'srq-12');
      expect(store.pendingValueRequest, isNull);
    });

    test('request.cancel withdraws the matching prompt only', () async {
      final gw = R56Gateway();
      final store = fresh(gw);
      addTearDown(store.dispose);

      gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
        'id': 'srq-21',
        'method': 'sudo',
        'params': {'session_id': 'live-x', 'command': 'sudo reboot'},
      })!);
      await Future<void>.delayed(Duration.zero);
      expect(store.pendingValueRequest?.id, 'srq-21');

      // A cancel naming a DIFFERENT request must not tear this card down.
      gw.pushEvent(const GatewayEvent(
          type: 'request.cancel',
          sessionId: 'live-x',
          payload: {'id': 'srq-99', 'method': 'sudo', 'reason': 'timeout'}));
      await Future<void>.delayed(Duration.zero);
      expect(store.pendingValueRequest?.id, 'srq-21');

      // The gateway withdrew THIS one (answered elsewhere, or it timed out).
      gw.pushEvent(const GatewayEvent(
          type: 'request.cancel',
          sessionId: 'live-x',
          payload: {
            'id': 'srq-21',
            'method': 'sudo',
            'reason': 'answered elsewhere',
          }));
      await Future<void>.delayed(Duration.zero);
      expect(store.pendingValueRequest, isNull,
          reason: 'the request is gone; a card that blocks the composer '
              'forever is worse than none (the app ignored this event)');
    });

    test('request.cancel clears only the approval card whose id it names',
        () async {
      final gw = R56Gateway();
      final store = fresh(gw);
      addTearDown(store.dispose);

      gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
        'id': 'srq-31',
        'method': 'approval',
        'params': {
          'session_id': 'live-x',
          'request_id': 'req-1',
          'command': 'rm -rf /tmp/x',
          'choices': ['once', 'deny'],
        },
      })!);
      await Future<void>.delayed(Duration.zero);
      expect(store.pendingRequest?.payload['request_id'], 'req-1');

      gw.pushEvent(const GatewayEvent(
          type: 'request.cancel',
          sessionId: 'live-x',
          payload: {'id': 'srq-zz', 'method': 'approval', 'reason': 'timeout'}));
      await Future<void>.delayed(Duration.zero);
      expect(store.pendingRequest, isNotNull,
          reason: 'a cancel for another request must not clear this card');

      gw.pushEvent(const GatewayEvent(
          type: 'request.cancel',
          sessionId: 'live-x',
          payload: {'id': 'srq-31', 'method': 'approval', 'reason': 'timeout'}));
      await Future<void>.delayed(Duration.zero);
      expect(store.pendingRequest, isNull);
    });

    test('resume re-arms the gateway open_requests snapshot', () async {
      // server.py _resume_response replays unanswered server requests so a
      // reconnecting client can answer them; the agent is parked until one
      // lands. Before this fix the app ignored the field entirely.
      final gw = R56Gateway();
      gw.resumeExtras = {
        'open_requests': [
          {
            'id': 'srq-41',
            'method': 'sudo',
            'params': {'session_id': 'live-x', 'command': 'sudo apt update'},
          },
          {
            'id': 'srq-42',
            'method': 'approval',
            'params': {
              'session_id': 'live-x',
              'request_id': 'req-2',
              'command': 'rm thing',
              'choices': ['once', 'deny'],
            },
          },
        ],
      };
      final store = fresh(gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      expect(store.pendingValueRequest?.id, 'srq-41',
          reason: 'the re-armed sudo prompt must be answerable, not silent');
      expect(store.pendingRequest?.payload['request_id'], 'req-2');
      expect(store.pendingRequest?.type, 'approval.request');
    });
  });
}
