import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/media/attachment_cache.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/store/chat_store.dart';
import 'package:talaria/src/widgets/message_bubble.dart';

/// Round-56 follow-ups from the delegated adversarial review: the review
/// found six defects in the round-56 fixes themselves (history reconcile
/// dropping refs, a stale secret card answering the NEXT request, retry
/// losing the cancelable transport id, disconnect leaving the value queue
/// and card identity behind, resume only appending open_requests instead of
/// reconciling, and literal code lines mistaken for attachment refs). Each
/// group below is proven red against the pre-fix store and green after.

final _cfg = GatewayConfig(url: 'http://localhost:1');

class R56bGateway extends GatewayClient {
  R56bGateway() : super(_cfg);
  final _events = StreamController<GatewayEvent>.broadcast(sync: true);
  final _requests = StreamController<ServerRequest>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];
  final replies = <Map<String, dynamic>>[];

  Map<String, dynamic> resumeExtras = const {};
  List<Map<String, dynamic>> historyMessages = const [];
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
    if (failNextRespondWith != null &&
        (method == 'clarify.respond' || method == 'approval.respond')) {
      final code = failNextRespondWith!;
      failNextRespondWith = null;
      throw GatewayError('transport failure', code: code);
    }
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

ChatStore fresh(R56bGateway gw) => ChatStore(config: _cfg, client: gw);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(AttachmentCache.clear);
  tearDown(MessageBubble.resetTestBuildCounts);

  group('review fix 1: history reconcile carries refs onto retained rows',
      () {
    test('a retained transcript gains the attachment a later read carries',
        () async {
      final gw = R56bGateway();
      gw.resumeExtras = {
        'messages': [
          // First read: the persisted row has no refs (or an older read won
          // the race before the image finished staging).
          {'role': 'user', 'text': 'see'},
          {'role': 'assistant', 'text': 'noted'},
        ],
      };
      gw.historyMessages = [
        {'role': 'user', 'text': 'see\n@image:/tmp/sess/b.png'},
        {'role': 'assistant', 'text': 'noted'},
      ];
      final store = fresh(gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');
      expect(store.messages.first.attachments, isEmpty);

      gw.pushEvent(const GatewayEvent(type: 'sessions.changed', payload: {}));
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(store.messages.first.attachments, ['@image:/tmp/sess/b.png'],
          reason: 'the same-roles merge retains the message OBJECT and used '
              'to copy only text - the fresh ref was silently dropped '
              '(review finding 1)');
      expect(store.messages.first.text, 'see');
      // No duplicate churn: the ref is on the retained row, not a replacement.
      expect(store.messages.length, 2);
    });

    test('setAttachments is quiet when the refs already match', () {
      final m = ChatMessage(
          role: 'user', text: 'x', attachments: const ['@file:a.md']);
      final r0 = m.revision;
      m.setAttachments(const ['@file:a.md']);
      expect(m.revision, r0,
          reason: 'a no-op reconcile must not repaint the row');
      m.setAttachments(const ['@file:a.md', '@image:/b.png']);
      expect(m.revision, greaterThan(r0));
      expect(m.attachments, ['@file:a.md', '@image:/b.png']);
    });
  });

  group('review fix 6: literal code is never mistaken for an attachment', () {
    test('an INDENTED ref look-alike stays literal text', () {
      // The gateway anchors persisted refs at the line start
      // (_IMAGE_REF_RE); an indented token is user-written code, and the
      // gateway itself never strips it.
      final r = ChatMessage.extractAttachmentRefs(
          'use it like this:\n    @file:notes.md');
      expect(r.text, 'use it like this:\n    @file:notes.md');
      expect(r.refs, isEmpty,
          reason: 'an indented code line must not become a phantom chip');
    });

    test('an unclosed fence keeps its tail literal', () {
      final r = ChatMessage.extractAttachmentRefs(
          '```text\n@file:example.txt');
      expect(r.text, '```text\n@file:example.txt');
      expect(r.refs, isEmpty);
    });

    test('a CLOSED fence followed by a real trailing ref still extracts', () {
      // The gateway appends persisted refs AFTER the text, fence or no fence.
      final r = ChatMessage.extractAttachmentRefs(
          '```text\n@file:example.txt\n```\n@image:/tmp/sess/shot.png');
      expect(r.text, '```text\n@file:example.txt\n```');
      expect(r.refs, ['@image:/tmp/sess/shot.png']);
    });
  });

  group('review fix 2: a value submission names its request', () {
    test('a stale submission for a withdrawn request answers nothing',
        () async {
      final gw = R56bGateway();
      final store = fresh(gw);
      addTearDown(store.dispose);

      gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
        'id': 'srq-61',
        'method': 'sudo',
        'params': {'session_id': 'live-x', 'command': 'sudo a'},
      })!);
      gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
        'id': 'srq-62',
        'method': 'secret',
        'params': {'session_id': 'live-x', 'env_var': 'K'},
      })!);
      await Future<void>.delayed(Duration.zero);

      // srq-61 is withdrawn (answered on another surface) WHILE its card is
      // still mounted with a typed secret. The card's Send lands after the
      // cancel - the store must refuse to hand that secret to srq-62.
      gw.pushEvent(const GatewayEvent(
          type: 'request.cancel',
          sessionId: 'live-x',
          payload: {'id': 'srq-61', 'method': 'sudo', 'reason': 'other'}));
      await Future<void>.delayed(Duration.zero);
      expect(store.pendingValueRequest?.id, 'srq-62');

      store.respondValue('typed-secret', requestId: 'srq-61');
      expect(gw.replies, isEmpty,
          reason: 'the stale card no longer names a live request; blindly '
              'dequeuing the head would answer srq-62 with the wrong secret '
              '(review finding 2)');
      expect(store.pendingValueRequest?.id, 'srq-62');

      // The live card still answers normally.
      store.respondValue('real-value', requestId: 'srq-62');
      expect(gw.replies.single['id'], 'srq-62');
    });
  });

  group('review fix 3: retry keeps the card cancelable', () {
    test('a transport-failed approval restored for retry still answers '
        'request.cancel', () async {
      final gw = R56bGateway();
      final store = fresh(gw);
      addTearDown(store.dispose);

      gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
        'id': 'srq-71',
        'method': 'approval',
        'params': {
          'session_id': 'live-x',
          'request_id': 'req-7',
          'command': 'rm x',
          'choices': ['once', 'deny'],
        },
      })!);
      await Future<void>.delayed(Duration.zero);

      // A real transport failure (not a gone-code): the card is restored for
      // retry. Before the fix the restore dropped the transport id, so a
      // later request.cancel could not name this card.
      gw.failNextRespondWith = 5000;
      await store.respondApproval(approved: true);
      expect(store.pendingRequest?.payload['request_id'], 'req-7');

      gw.pushEvent(const GatewayEvent(
          type: 'request.cancel',
          sessionId: 'live-x',
          payload: {'id': 'srq-71', 'method': 'approval', 'reason': 'timeout'}));
      await Future<void>.delayed(Duration.zero);
      expect(store.pendingRequest, isNull,
          reason: 'the restored card must carry the transport id the gateway '
              'names (review finding 3)');
    });
  });

  group('review fix 4+5: lifecycle reconciliation', () {
    test('disconnect clears the card identity AND the value queue', () async {
      final gw = R56bGateway();
      final store = fresh(gw);
      addTearDown(store.dispose);

      gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
        'id': 'srq-81',
        'method': 'sudo',
        'params': {'session_id': 'live-x', 'command': 'sudo a'},
      })!);
      gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
        'id': 'srq-82',
        'method': 'approval',
        'params': {
          'session_id': 'live-x',
          'request_id': 'req-8',
          'command': 'rm x',
          'choices': ['once', 'deny'],
        },
      })!);
      await Future<void>.delayed(Duration.zero);
      expect(store.pendingValueRequest?.id, 'srq-81');
      expect(store.pendingRequest?.payload['request_id'], 'req-8');

      await store.disconnect();
      expect(store.pendingValueRequest, isNull);
      expect(store.pendingRequest, isNull);

      // Stale ids must not suppress the SAME still-open request a reconnect
      // re-delivers: the resume re-arm runs (dedupe compares against the
      // freshly armed entry, not the pre-disconnect ghost).
      gw.resumeExtras = {
        'open_requests': [
          {
            'id': 'srq-81',
            'method': 'sudo',
            'params': {'session_id': 'live-x', 'command': 'sudo a'},
          },
        ],
      };
      await store.resumeSession('a');
      expect(store.pendingValueRequest?.id, 'srq-81');
    });

    test('a resume whose snapshot dropped a queued prompt retires the local '
        'card', () async {
      // Another surface answered srq-91 during the outage. The gateway
      // settles a value answer WITHOUT emitting request.cancel
      // (server_requests.resolve_response), so the local card can only be
      // retired by reconciling against the resume's open_requests snapshot.
      final gw = R56bGateway();
      final store = fresh(gw);
      addTearDown(store.dispose);

      gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
        'id': 'srq-91',
        'method': 'sudo',
        'params': {'session_id': 'live-x', 'command': 'sudo a'},
      })!);
      await Future<void>.delayed(Duration.zero);
      expect(store.pendingValueRequest?.id, 'srq-91');

      gw.resumeExtras = {'open_requests': const <Object>[]};
      final ok = await store.resumeSession('a');
      expect(ok, isTrue);
      expect(store.pendingValueRequest, isNull,
          reason: 'the authoritative snapshot no longer holds it; an empty '
              'snapshot must retire, not just append (review finding 5)');
    });

    test('a resume snapshot that still holds the prompt keeps it (no '
        'self-retirement)', () async {
      final gw = R56bGateway();
      final store = fresh(gw);
      addTearDown(store.dispose);

      gw.pushRequest(serverRequestFromFrame(const <String, dynamic>{
        'id': 'srq-92',
        'method': 'sudo',
        'params': {'session_id': 'live-x', 'command': 'sudo a'},
      })!);
      await Future<void>.delayed(Duration.zero);

      gw.resumeExtras = {
        'open_requests': [
          {
            'id': 'srq-92',
            'method': 'sudo',
            'params': {'session_id': 'live-x', 'command': 'sudo a'},
          },
        ],
      };
      await store.resumeSession('a');
      expect(store.pendingValueRequests.length, 1,
          reason: 'dedupe keeps one live entry; reconcile must not retire a '
              'request the snapshot still lists');
    });
  });
}
