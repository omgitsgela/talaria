import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/store/chat_store.dart';

final config = GatewayConfig(url: 'http://localhost:1');

/// Mock gateway that records RPC calls and delegates to [handle].
class AttachmentGateway extends GatewayClient {
  AttachmentGateway() : super(config);
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
    if (handle != null) {
      final override = await handle!(method, params);
      // Empty override maps mean "no opinion" — fall through to the
      // built-in lifecycle defaults so resume/create still yield live ids.
      if (override.isNotEmpty) return override;
    }
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
      'session.create' => {'session_id': 'new-sid'},
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

  // ── Bug 1: detachAttachment only removes local, never calls image.detach ──
  group('detachAttachment', () {
    test('calls image.detach on gateway to unqueue image', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'session.resume' => {
          'session_id': 'live-${p['session_id']}',
          'resumed': p['session_id'],
          'messages': <Map<String, dynamic>>[],
        },
        'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/upload_001.png',
          'count': 1,
        },
        'image.detach' => {
          'detached': true,
          'count': 0,
        },
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachImageBytes([0x89, 0x50], filename: 'test.png');
      expect(store.pendingAttachments, ['/tmp/upload_001.png']);

      // detachAttachment must call image.detach on gateway (now async)
      await store.detachAttachment('/tmp/upload_001.png');
      expect(store.pendingAttachments, isEmpty);

      // Verify image.detach was called with correct path and session
      final detachCalls =
          gw.calls.where((c) => c.$1 == 'image.detach').toList();
      expect(detachCalls, hasLength(1),
          reason: 'image.detach must be called to unqueue the image on gateway');
      expect(detachCalls.first.$2['path'], '/tmp/upload_001.png');
      expect(detachCalls.first.$2['session_id'], 'live-a');
    });

    test('preserves chip when gateway detach fails', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'session.resume' => {
          'session_id': 'live-${p['session_id']}',
          'resumed': p['session_id'],
          'messages': <Map<String, dynamic>>[],
        },
        'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/upload_002.png',
          'count': 1,
        },
        'image.detach' =>
          throw GatewayError('session not found', code: 4001),
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachImageBytes([0x89, 0x50], filename: 'test.png');
      expect(store.pendingAttachments, ['/tmp/upload_002.png']);

      // On gateway failure, chip should remain so user can retry
      await store.detachAttachment('/tmp/upload_002.png');
      expect(store.pendingAttachments, ['/tmp/upload_002.png'],
          reason: 'chip must remain when gateway detach fails');
    });
  });

  // ── Bug 2: send() never prepends file refs ───────────────────────────────
  group('file attachment refs in prompt', () {
    test('send prepends @file refs from pending file attachments', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'file.attach' => {
          'attached': true,
          'name': 'readme.md',
          'path': '/tmp/sess/readme.md',
          'ref_path': 'readme.md',
          'ref_text': '@file:readme.md',
        },
        'prompt.submit' => {'status': 'streaming'},
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachFileBytes([0x48, 0x69], name: 'readme.md');
      expect(store.pendingAttachments, contains('@file:readme.md'));

      await store.send('explain this');

      // The prompt.submit text must include the file ref
      final submitCalls =
          gw.calls.where((c) => c.$1 == 'prompt.submit').toList();
      expect(submitCalls, hasLength(1));
      final submittedText = submitCalls.first.$2['text'] as String;
      expect(submittedText, contains('@file:readme.md'),
          reason: 'file ref must be prepended to prompt text');
      expect(submittedText, contains('explain this'),
          reason: 'original text must still be present');
    });

    test('send prepends multiple file refs', () async {
      final gw = AttachmentGateway();
      var callCount = 0;
      gw.handle = (m, p) async => switch (m) {
        'file.attach' => () {
            callCount++;
            return {
              'attached': true,
              'name': 'file_$callCount.txt',
              'path': '/tmp/sess/file_$callCount.txt',
              'ref_path': 'file_$callCount.txt',
              'ref_text': '@file:file_$callCount.txt',
            };
          }(),
        'prompt.submit' => {'status': 'streaming'},
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachFileBytes([0x41], name: 'file1.txt');
      await store.attachFileBytes([0x42], name: 'file2.txt');
      expect(store.pendingAttachments, hasLength(2));

      await store.send('compare these');

      final submitCalls =
          gw.calls.where((c) => c.$1 == 'prompt.submit').toList();
      final submittedText = submitCalls.first.$2['text'] as String;
      expect(submittedText, contains('@file:file_1.txt'));
      expect(submittedText, contains('@file:file_2.txt'));
    });
  });

  // ── Bug 3: attach on new draft uses empty session id ─────────────────────
  group('attach creates session on draft', () {
    test('attachImageBytes creates session when none exists', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'session.create' => {'session_id': 'created-sid'},
        'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/upload.png',
          'count': 1,
        },
        _ => <String, dynamic>{},
      };
      // Simulate fresh start with no session (draft state)
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      // Do NOT resume — stay in draft (activeSessionId == null)

      await store.attachImageBytes([0x89, 0x50]);

      // Must have created a session before attaching
      final createCalls =
          gw.calls.where((c) => c.$1 == 'session.create').toList();
      expect(createCalls, hasLength(1),
          reason: 'must create session before attaching image on draft');
      expect(store.activeSessionId, 'created-sid');
      expect(store.pendingAttachments, ['/tmp/upload.png']);
    });

    test('attachFileBytes creates session when none exists', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'session.create' => {'session_id': 'file-sid'},
        'file.attach' => {
          'attached': true,
          'name': 'data.csv',
          'path': '/tmp/sess/data.csv',
          'ref_path': 'data.csv',
          'ref_text': '@file:data.csv',
        },
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);

      await store.attachFileBytes([0x44, 0x45], name: 'data.csv');

      final createCalls =
          gw.calls.where((c) => c.$1 == 'session.create').toList();
      expect(createCalls, hasLength(1),
          reason: 'must create session before attaching file on draft');
      expect(store.activeSessionId, 'file-sid');
    });

    test('attach reuses existing session', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'session.resume' => {
          'session_id': 'live-a',
          'resumed': 'a',
          'messages': <Map<String, dynamic>>[],
        },
        'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/upload.png',
          'count': 1,
        },
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachImageBytes([0x89, 0x50]);

      // Should NOT create a new session when one already exists
      final createCalls =
          gw.calls.where((c) => c.$1 == 'session.create').toList();
      expect(createCalls, isEmpty,
          reason: 'must not create duplicate session');
    });
  });

  // ── Bug 4: pending attachments never cleared ─────────────────────────────
  group('pending attachments lifecycle', () {
    test('send clears pending attachments on success', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/img.png',
          'count': 1,
        },
        'prompt.submit' => {'status': 'streaming'},
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachImageBytes([0x89, 0x50]);
      expect(store.pendingAttachments, isNotEmpty);

      await store.send('hello');
      expect(store.pendingAttachments, isEmpty,
          reason: 'send must clear pending attachments');
    });

    test('send preserves pending attachments on failure', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/img.png',
          'count': 1,
        },
        'prompt.submit' =>
          throw GatewayError('session busy', code: 4009),
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachImageBytes([0x89, 0x50]);
      expect(store.pendingAttachments, ['/tmp/img.png']);

      // send fails — attachments should remain
      // (send catches the error internally; we ignore the returned future)
      await store.send('hello');
      expect(store.pendingAttachments, ['/tmp/img.png'],
          reason: 'failed send must preserve pending attachments');
    });

    test('resumeSession clears pending attachments', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/img.png',
          'count': 1,
        },
        'session.resume' => {
          'session_id': 'live-b',
          'resumed': 'b',
          'messages': <Map<String, dynamic>>[],
          'info': {'model': 'm'},
        },
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachImageBytes([0x89, 0x50]);
      expect(store.pendingAttachments, isNotEmpty);

      // Switching sessions must clear stale attachments
      await store.resumeSession('b');
      expect(store.pendingAttachments, isEmpty,
          reason: 'resume must clear pending attachments from old session');
    });

    test('createSession clears pending attachments', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/img.png',
          'count': 1,
        },
        'session.create' => {'session_id': 'new-sid'},
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachImageBytes([0x89, 0x50]);
      expect(store.pendingAttachments, isNotEmpty);

      await store.createSession();
      expect(store.pendingAttachments, isEmpty,
          reason: 'new session must clear pending attachments');
    });

    test('new draft clears pending attachments', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/img.png',
          'count': 1,
        },
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachImageBytes([0x89, 0x50]);
      expect(store.pendingAttachments, isNotEmpty);

      // disconnect + reconnect should end up with a clean slate
      await store.disconnect();
      expect(store.pendingAttachments, isEmpty,
          reason: 'disconnect must clear pending attachments');
    });
  });

  // ── Error handling for attach methods ─────────────────────────────────────
  group('attach error handling', () {
    test('attachImageBytes returns error and does not add to pending',
        () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'image.attach_bytes' =>
          throw GatewayError('image too large', code: 4016),
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      final result = await store.attachImageBytes([0x89, 0x50]);
      expect(result, contains('image too large'));
      expect(store.pendingAttachments, isEmpty,
          reason: 'failed attach must not add to pending list');
    });

    test('attachFileBytes returns error on failure', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'file.attach' =>
          throw GatewayError('file too large', code: 5028),
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      final result = await store.attachFileBytes([0x44], name: 'big.bin');
      expect(result, contains('file too large'));
      expect(store.pendingAttachments, isEmpty);
    });
  });

  // ── Cross-session attachment lifecycle (correction pass) ──────────────
  group('cross-session attachment lifecycle', () {
    test('attachImageBytes discards result when session switches mid-flight',
        () async {
      final gw = AttachmentGateway();
      final attachCompleter = Completer<Map<String, dynamic>>();
      var attachRequested = false;
      gw.handle = (m, p) async {
        if (m == 'image.attach_bytes') {
          attachRequested = true;
          return attachCompleter.future;
        }
        return switch (m) {
          'session.create' => {'session_id': 'new-sid'},
          'session.resume' => {
            'session_id': 'live-${p['session_id']}',
            'resumed': p['session_id'],
            'messages': <Map<String, dynamic>>[],
          },
          'image.detach' => {'detached': true, 'count': 0},
          _ => <String, dynamic>{},
        };
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');
      expect(store.activeSessionId, 'live-a');

      // Start an attach on session a
      final attachFuture =
          store.attachImageBytes([0x89, 0x50], filename: 'test.png');
      // Let _ensureSession resolve but don't complete the image attach yet
      await Future<void>.delayed(Duration.zero);
      expect(attachRequested, isTrue);

      // Switch to session b while attach is in flight
      await store.resumeSession('b');
      expect(store.activeSessionId, 'live-b');

      // Complete the old attach request
      attachCompleter.complete({
        'attached': true,
        'path': '/tmp/ghost.png',
        'count': 1,
      });
      final result = await attachFuture;

      // Must discard the stale result
      expect(result, isEmpty,
          reason: 'stale attach must return empty after session switch');
      expect(store.pendingAttachments, isEmpty,
          reason: 'stale ref must not enter the pending list');

      // Must have attempted to detach from the OLD session
      final detachCalls =
          gw.calls.where((c) => c.$1 == 'image.detach').toList();
      expect(detachCalls, hasLength(1),
          reason: 'must detach ghost image from old session');
      expect(detachCalls.first.$2['session_id'], 'live-a');
      expect(detachCalls.first.$2['path'], '/tmp/ghost.png');
    });

    test('attachFileBytes discards result when session switches mid-flight',
        () async {
      final gw = AttachmentGateway();
      final attachCompleter = Completer<Map<String, dynamic>>();
      gw.handle = (m, p) async {
        if (m == 'file.attach') return attachCompleter.future;
        return switch (m) {
          'session.create' => {'session_id': 'new-sid'},
          'session.resume' => {
            'session_id': 'live-${p['session_id']}',
            'resumed': p['session_id'],
            'messages': <Map<String, dynamic>>[],
          },
          _ => <String, dynamic>{},
        };
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      final attachFuture = store.attachFileBytes([0x48], name: 'data.csv');
      await Future<void>.delayed(Duration.zero);

      await store.resumeSession('b');

      attachCompleter.complete({
        'attached': true,
        'ref_text': '@file:data.csv',
        'path': '/tmp/sess/data.csv',
      });
      final result = await attachFuture;

      expect(result, isEmpty,
          reason: 'stale file attach must return empty after session switch');
      expect(store.pendingAttachments, isEmpty);
    });

    test('concurrent _ensureSession creates only one session', () async {
      final gw = AttachmentGateway();
      var createCount = 0;
      final createCompleter = Completer<Map<String, dynamic>>();
      gw.handle = (m, p) async {
        if (m == 'session.create') {
          createCount++;
          return createCompleter.future;
        }
        if (m == 'image.attach_bytes') {
          return {
            'attached': true,
            'path': '/tmp/upload_$createCount.png',
            'count': 1,
          };
        }
        return <String, dynamic>{};
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);

      // Fire two concurrent attaches while no session exists
      final f1 = store.attachImageBytes([0x01], filename: 'a.png');
      final f2 = store.attachImageBytes([0x02], filename: 'b.png');
      await Future<void>.delayed(Duration.zero);

      // Complete the shared session creation
      createCompleter.complete({'session_id': 'shared-sid'});
      await Future.wait([f1, f2]);

      expect(createCount, 1,
          reason: 'concurrent _ensureSession must share one creation');
      expect(store.activeSessionId, 'shared-sid');
      expect(store.pendingAttachments, hasLength(2));
    });

    test('send removes only snapshot attachments, not newly added ones',
        () async {
      final gw = AttachmentGateway();
      final submitCompleter = Completer<Map<String, dynamic>>();
      var submitStarted = false;
      gw.handle = (m, p) async {
        if (m == 'image.attach_bytes') {
          return {
            'attached': true,
            'path': '/tmp/${p['filename']}',
            'count': 1,
          };
        }
        if (m == 'prompt.submit') {
          submitStarted = true;
          return submitCompleter.future;
        }
        return <String, dynamic>{};
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      // Attach two images
      await store.attachImageBytes([0x01], filename: 'old1.png');
      await store.attachImageBytes([0x02], filename: 'old2.png');
      expect(store.pendingAttachments, hasLength(2));

      // Start sending
      final sendFuture = store.send('describe these');
      await Future<void>.delayed(Duration.zero);
      expect(submitStarted, isTrue);

      // While send is in flight, add a new attachment
      await store.attachImageBytes([0x03], filename: 'new.png');
      expect(store.pendingAttachments, hasLength(3),
          reason: 'new attach during send should be in pending');

      // Complete the submit
      submitCompleter.complete({'status': 'streaming'});
      await sendFuture;

      // Only the snapshot refs should be removed; the new one survives
      expect(store.pendingAttachments, ['/tmp/new.png'],
          reason: 'only snapshot refs removed, not in-flight additions');
    });

    test('resumeSession detaches gateway images before clearing', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'session.resume' => {
          'session_id': 'live-${p['session_id']}',
          'resumed': p['session_id'],
          'messages': <Map<String, dynamic>>[],
        },
        'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/img_old.png',
          'count': 1,
        },
        'image.detach' => {'detached': true, 'count': 0},
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachImageBytes([0x89, 0x50], filename: 'test.png');
      expect(store.pendingAttachments, ['/tmp/img_old.png']);

      // Switch sessions — must detach the image from old session first
      await store.resumeSession('b');

      final detachCalls =
          gw.calls.where((c) => c.$1 == 'image.detach').toList();
      expect(detachCalls, hasLength(1),
          reason: 'must detach image before session switch');
      expect(detachCalls.first.$2['session_id'], 'live-a');
      expect(detachCalls.first.$2['path'], '/tmp/img_old.png');
      expect(store.pendingAttachments, isEmpty);
    });

    test('disconnect detaches gateway images before clearing', () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'session.resume' => {
          'session_id': 'live-${p['session_id']}',
          'resumed': p['session_id'],
          'messages': <Map<String, dynamic>>[],
        },
        'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/disconnect_img.png',
          'count': 1,
        },
        'image.detach' => {'detached': true, 'count': 0},
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachImageBytes([0x89, 0x50], filename: 'test.png');
      expect(store.pendingAttachments, ['/tmp/disconnect_img.png']);

      await store.disconnect();

      final detachCalls =
          gw.calls.where((c) => c.$1 == 'image.detach').toList();
      expect(detachCalls, hasLength(1),
          reason: 'must detach image before disconnect');
      expect(store.pendingAttachments, isEmpty);
    });
  });

  // ── Empty-text image-only send (correction pass) ──────────────────────
  group('empty-text image-only send', () {
    test('send succeeds with empty text and pending image attachments',
        () async {
      final gw = AttachmentGateway();
      gw.handle = (m, p) async => switch (m) {
        'session.resume' => {
          'session_id': 'live-${p['session_id']}',
          'resumed': p['session_id'],
          'messages': <Map<String, dynamic>>[],
        },
        'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/img_only.png',
          'count': 1,
        },
        'prompt.submit' => {'status': 'streaming'},
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.attachImageBytes([0x89, 0x50], filename: 'photo.png');
      expect(store.pendingAttachments, ['/tmp/img_only.png']);

      // Send with empty text — should succeed because attachments exist
      await store.send('');

      final submitCalls =
          gw.calls.where((c) => c.$1 == 'prompt.submit').toList();
      expect(submitCalls, hasLength(1),
          reason: 'image-only send must submit prompt');
      expect(submitCalls.first.$2['text'], isEmpty);
      expect(submitCalls.first.$2['session_id'], 'live-a');
      expect(store.pendingAttachments, isEmpty);
    });

    test('send returns early with empty text and no attachments', () async {
      final gw = AttachmentGateway();
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');

      await store.send('');

      final submitCalls =
          gw.calls.where((c) => c.$1 == 'prompt.submit').toList();
      expect(submitCalls, isEmpty,
          reason: 'truly empty send must not submit');
    });
  });

  // ── Final parent corrections ─────────────────────────────────────────
  group('lifecycle failure safety', () {
    test('failed detach on resume aborts the switch and preserves refs',
        () async {
      final gw = AttachmentGateway();
      var failDetach = false;
      gw.handle = (m, p) async => switch (m) {
        'session.resume' => {
          'session_id': 'live-${p['session_id']}',
          'resumed': p['session_id'],
          'messages': <Map<String, dynamic>>[],
        },
        'image.attach_bytes' => {
          'attached': true,
          'path': '/tmp/guarded.png',
          'count': 1,
        },
        'image.detach' => failDetach
            ? throw GatewayError('gateway unreachable')
            : {'detached': true, 'count': 0},
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await store.resumeSession('a');
      await store.attachImageBytes([0x89, 0x50], filename: 'guarded.png');
      expect(store.pendingAttachments, ['/tmp/guarded.png']);

      // Now make detach fail and try to switch sessions.
      failDetach = true;
      await store.resumeSession('b');

      // Switch must abort: still on live-a, ref preserved, no session.resume
      // for b was issued after the failed detach.
      expect(store.activeSessionId, 'live-a',
          reason: 'failed detach must abort the session switch');
      expect(store.pendingAttachments, ['/tmp/guarded.png'],
          reason: 'still-queued image must remain visible, not silently lost');
      expect(store.statusLine, contains('detach failed'));

      // Recover: detach succeeds now, switch proceeds and clears the ref.
      failDetach = false;
      await store.resumeSession('b');
      expect(store.activeSessionId, 'live-b');
      expect(store.pendingAttachments, isEmpty);
    });

    test('stale in-flight session.create does not clobber a newer selection',
        () async {
      final gw = AttachmentGateway();
      final createGate = Completer<Map<String, dynamic>>();
      gw.handle = (m, p) async => switch (m) {
        'session.resume' => {
          'session_id': 'live-${p['session_id']}',
          'resumed': p['session_id'],
          'messages': <Map<String, dynamic>>[],
        },
        // Hold session.create open so a resume can interleave.
        'session.create' => await createGate.future,
        'image.attach_bytes' => {'attached': true, 'path': '/tmp/stale.png'},
        _ => <String, dynamic>{},
      };
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);

      // Start an attach on a draft: begins an in-flight session.create.
      final attach = store.attachImageBytes([0x89, 0x50], filename: 's.png');
      await Future<void>.delayed(Duration.zero);

      // User resumes a real session while create is still in flight.
      await store.resumeSession('a');
      expect(store.activeSessionId, 'live-a');

      // The stale create now resolves; it must not steal the selection and
      // the attach must be discarded rather than attached to the wrong sid.
      createGate.complete({'session_id': 'stale-created'});
      final ref = await attach;
      expect(store.activeSessionId, 'live-a',
          reason: 'late session.create must not overwrite user selection');
      expect(ref, isEmpty,
          reason: 'attach superseded mid-flight must be discarded');
      expect(store.pendingAttachments, isEmpty);
    });
  });
}
