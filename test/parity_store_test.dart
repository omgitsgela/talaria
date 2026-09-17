import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/store/chat_store.dart';

final config = GatewayConfig(url: 'http://localhost:1');

/// Fake tui_gateway client that records every RPC call and lets tests supply
/// per-method responses via [responses].
class ParityGateway extends GatewayClient {
  ParityGateway() : super(config);

  final calls = <(String, Map<String, dynamic>)>[];
  final responses = <String, Map<String, dynamic>>{};
  final errorMethods = <String, String>{};
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  /// Sessions flagged hidden via session.set_hidden; the fake models the real
  /// gateway by excluding them from subsequent session.list results.
  final hidden = <String>{};

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
    final err = errorMethods[method];
    if (err != null) throw GatewayError(err);
    // Model the real gateway: hiding a session removes it from the roster.
    if (method == 'session.set_hidden') {
      final id = (params['session_id'] ?? '') as String;
      if (params['hidden'] == true) {
        hidden.add(id);
      } else {
        hidden.remove(id);
      }
    }
    if (method == 'session.list' && responses.containsKey('session.list')) {
      final raw = responses['session.list']!;
      final rows = (raw['sessions'] as List? ?? const [])
          .where((r) => r is Map && !hidden.contains(r['id']))
          .toList();
      return {'sessions': rows};
    }
    if (responses.containsKey(method)) return responses[method]!;
    // Sensible default: a resume establishes a live session keyed off the
    // requested id, so store methods that need an active session work.
    if (method == 'session.resume') {
      final key = (params['session_id'] ?? 'stored') as String;
      return {
        'session_id': 'live-$key',
        'resumed': key,
        'messages': <Map<String, dynamic>>[],
      };
    }
    return const {};
  }

  void emit(String type, Map<String, dynamic> payload, {String? sid}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: payload));

  (String, Map<String, dynamic>)? callFor(String method) {
    for (final c in calls.reversed) {
      if (c.$1 == method) return c;
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    await pushed.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── Session management (real session.* contracts) ─────────────────
  test('setTitle posts session.title and updates the roster row', () async {
    final gw = ParityGateway();
    gw.responses['session.title'] = {'title': 'My new title', 'pending': false};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    // Seed a roster row to rename.
    gw.responses['session.list'] = {
      'sessions': [
        {'id': 's1', 'title': 'old', 'preview': 'p'}
      ]
    };
    await store.loadSessions();
    await store.setTitle('s1', 'My new title');
    final c = gw.callFor('session.title')!;
    expect(c.$2['session_id'], 's1');
    expect(c.$2['title'], 'My new title');
    expect(store.sessions.single.title, 'My new title');
  });

  test('setTitle with blank title is a client-side no-op (no RPC)', () async {
    final gw = ParityGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.setTitle('s1', '   ');
    expect(gw.callFor('session.title'), isNull);
  });

  test('setHidden true posts session.set_hidden and removes the row', () async {
    final gw = ParityGateway();
    gw.responses['session.set_hidden'] = {'hidden': true, 'session_key': 's2'};
    gw.responses['session.list'] = {
      'sessions': [
        {'id': 's2', 'title': 'hide me'},
        {'id': 's3', 'title': 'keep me'}
      ]
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.loadSessions();
    expect(store.sessions, hasLength(2));
    await store.setHidden('s2', true);
    final c = gw.callFor('session.set_hidden')!;
    expect(c.$2['session_id'], 's2');
    expect(c.$2['hidden'], true);
    // After reload, only the unhidden row remains.
    expect(store.sessions.map((s) => s.id), ['s3']);
  });

  test('compressSession posts session.compress for the active session',
      () async {
    final gw = ParityGateway();
    gw.responses['session.compress'] = {'compressed': true};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');
    final res = await store.compressSession();
    final c = gw.callFor('session.compress')!;
    expect(c.$2['session_id'], 'live-a');
    expect(res, 'Compressed');
  });

  test('compressSession surfaces a held lock message', () async {
    final gw = ParityGateway();
    gw.responses['session.compress'] = {
      'compressed': false,
      'lock_held': true,
      'message': 'held by /compact'
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');
    final res = await store.compressSession();
    expect(res, 'held by /compact');
  });

  test('compressSession with no active session is a no-op', () async {
    final gw = ParityGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    final res = await store.compressSession();
    expect(res, isNull);
    expect(gw.callFor('session.compress'), isNull);
  });

  test('moveWorkspace posts session.workspace.move by session_key + cwd',
      () async {
    final gw = ParityGateway();
    gw.responses['session.workspace.move'] = {
      'cwd': '/home/user/newdir',
      'branch': 'main',
      'git_repo_root': '/home/user/newdir'
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    final res = await store.moveWorkspace('sk-1', '/home/user/newdir');
    final c = gw.callFor('session.workspace.move')!;
    expect(c.$2['session_key'], 'sk-1');
    expect(c.$2['cwd'], '/home/user/newdir');
    expect(res, '/home/user/newdir');
  });

  test('loadActiveList parses session.active_list into activeList', () async {
    final gw = ParityGateway();
    gw.responses['session.active_list'] = {
      'sessions': [
        {
          'session_id': 'live-1',
          'title': 'A',
          'model': 'gpt',
          'cwd': '/x',
          'is_current': true,
          'running': false
        },
        {
          'session_id': 'live-2',
          'title': 'B',
          'model': 'claude',
          'running': true
        }
      ]
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.loadActiveList();
    expect(store.activeList, hasLength(2));
    expect(store.activeList[0].id, 'live-1');
    expect(store.activeList[0].isCurrent, isTrue);
    expect(store.activeList[1].running, isTrue);
  });

  // ── Slash commands ─────────────────────────────────────────────────
  test('completeSlash posts complete.slash and returns items', () async {
    final gw = ParityGateway();
    gw.responses['complete.slash'] = {
      'items': [
        {'text': '/compress', 'display': '/compress', 'meta': 'Compress', 'kind': 'command'}
      ],
      'replace_from': 1
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    final res = await store.completeSlash('/com');
    final c = gw.callFor('complete.slash')!;
    expect(c.$2['text'], '/com');
    expect(res['items'], isA<List>());
    expect((res['items'] as List).single['text'], '/compress');
  });

  test('completeSlash swallows errors and returns empty items', () async {
    final gw = ParityGateway();
    gw.errorMethods['complete.slash'] = 'boom';
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    final res = await store.completeSlash('/x');
    expect(res['items'], isEmpty);
  });

  test('execSlash posts slash.exec with session + command', () async {
    final gw = ParityGateway();
    gw.responses['slash.exec'] = {'output': 'Compacted 12 messages'};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');
    final out = await store.execSlash('/compress');
    final c = gw.callFor('slash.exec')!;
    expect(c.$2['session_id'], 'live-a');
    expect(c.$2['command'], '/compress');
    expect(out, 'Compacted 12 messages');
  });

  test('execSlash with no active session returns a guard message', () async {
    final gw = ParityGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    final out = await store.execSlash('/model');
    expect(out, 'No active session');
    expect(gw.callFor('slash.exec'), isNull);
  });

  // ── Attachments ────────────────────────────────────────────────────
  test('attachImageBytes base64-encodes and posts image.attach_bytes',
      () async {
    final gw = ParityGateway();
    gw.responses['image.attach_bytes'] = {'path': '/tmp/img-abc.png'};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');
    final bytes = [1, 2, 3, 4, 255];
    final ref = await store.attachImageBytes(bytes, filename: 'x.png', ext: 'png');
    final c = gw.callFor('image.attach_bytes')!;
    expect(base64Decode(c.$2['content_base64'] as String), bytes);
    expect(c.$2['filename'], 'x.png');
    expect(c.$2['ext'], 'png');
    expect(ref, '/tmp/img-abc.png');
    expect(store.pendingAttachments, ['/tmp/img-abc.png']);
  });

  test('attachFileBytes posts a data: URL and records the ref', () async {
    final gw = ParityGateway();
    gw.responses['file.attach'] = {'path': '/tmp/doc-xyz.pdf'};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');
    final ref = await store.attachFileBytes([10, 20], name: 'doc.pdf');
    final c = gw.callFor('file.attach')!;
    expect((c.$2['data_url'] as String).startsWith('data:;base64,'), isTrue);
    expect(ref, '/tmp/doc-xyz.pdf');
  });

  test('detachAttachment removes a pending ref', () async {
    final gw = ParityGateway();
    gw.responses['image.attach_bytes'] = {'path': '/tmp/a.png'};
    gw.responses['file.attach'] = {'path': '/tmp/b.txt', 'ref_text': '@file:b.txt'};
    gw.responses['image.detach'] = {'detached': true, 'count': 0};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');
    await store.attachImageBytes([1], filename: 'a.png');
    await store.attachFileBytes([2], name: 'b.txt');
    expect(store.pendingAttachments, hasLength(2));
    await store.detachAttachment('/tmp/a.png');
    expect(store.pendingAttachments, ['@file:b.txt']);
  });

  // ── HUD / status ───────────────────────────────────────────────────
  test('pollBattery stores the gateway battery map', () async {
    final gw = ParityGateway();
    gw.responses['system.battery'] = {'level': 0.72, 'charging': true};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.pollBattery();
    expect(store.battery['level'], 0.72);
    expect(store.battery['charging'], true);
  });

  test('pollVerification stores the nested verification map', () async {
    final gw = ParityGateway();
    gw.responses['verification.status'] = {
      'verification': {'status': 'verified', 'evidence': {'tests': 12}}
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.pollVerification();
    expect(store.verification['status'], 'verified');
  });

  test('pollSubscription stores the subscription map', () async {
    final gw = ParityGateway();
    gw.responses['subscription.preview'] = {'ok': true, 'plan': 'pro'};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.pollSubscription();
    expect(store.subscription['plan'], 'pro');
  });

  test('toggleVoice posts voice.toggle and reflects the enabled flag', () async {
    final gw = ParityGateway();
    gw.responses['voice.toggle'] = {'enabled': true};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    final on = await store.toggleVoice();
    expect(gw.callFor('voice.toggle'), isNotNull);
    expect(on, isTrue);
    expect(store.voiceOn, isTrue);
  });

  test('voice.transcript event auto-sends the transcript into the session',
      () async {
    final gw = ParityGateway();
    gw.responses['session.resume'] = {
      'session_id': 'live-a',
      'resumed': 'a',
      'messages': <Map<String, dynamic>>[]
    };
    gw.responses['session.create'] = {'session_id': 'live-a'};
    gw.responses['prompt.submit'] = {};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');
    expect(store.activeSessionId, 'live-a');

    // A real VAD transcript: the store must submit it as a prompt.
    gw.emit('voice.transcript', {'text': 'hello from voice'}, sid: 'live-a');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final submit = gw.callFor('prompt.submit');
    expect(submit, isNotNull);
    expect(submit!.$2['text'], 'hello from voice');
    expect(submit.$2['session_id'], 'live-a');

    // Stop phrases and no-speech limits must NOT be submitted as prompts.
    gw.calls.clear();
    gw.emit('voice.transcript', {'text': 'stop', 'stop_phrase': true},
        sid: 'live-a');
    gw.emit('voice.transcript', {'no_speech_limit': true}, sid: 'live-a');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(gw.callFor('prompt.submit'), isNull);
  });

  // ── Settings (config.get / config.set / model) ─────────────────────
  test('configGet reads the value from the config.get result', () async {
    final gw = ParityGateway();
    gw.responses['config.get'] = {'value': 'fast'};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    final v = await store.configGet('fast');
    final c = gw.callFor('config.get')!;
    expect(c.$2['key'], 'fast');
    expect(v, 'fast');
  });

  test('configSet posts key/value and returns the applied value', () async {
    final gw = ParityGateway();
    gw.responses['config.set'] = {'value': 'dark'};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    final applied = await store.configSet('theme', 'dark');
    final c = gw.callFor('config.set')!;
    expect(c.$2['key'], 'theme');
    expect(c.$2['value'], 'dark');
    expect(applied, 'dark');
  });

  test('setModel posts config.set model and updates currentModel', () async {
    final gw = ParityGateway();
    gw.responses['config.set'] = {'value': 'openai/gpt-5'};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');
    final applied = await store.setModel('openai/gpt-5');
    final c = gw.callFor('config.set')!;
    expect(c.$2['key'], 'model');
    expect(c.$2['value'], 'openai/gpt-5');
    expect(c.$2['session_id'], 'live-a');
    expect(applied.isSuccess, isTrue);
    expect(applied.value, 'openai/gpt-5');
    expect(store.currentModel, 'openai/gpt-5');
  });

  test('setModel surfaces confirm_required for expensive models', () async {
    final gw = ParityGateway();
    gw.responses['config.set'] = {
      'confirm_required': true,
      'confirm_message': 'expensive',
      'value': 'gpt-5'
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    final out = await store.setModel('gpt-5');
    expect(out.isConfirmRequired, isTrue);
    expect(out.value, 'gpt-5');
    expect(store.statusLine, contains('Expensive model'));
    // currentModel must NOT be updated when confirmation is required.
    expect(store.currentModel, isNot('gpt-5'));
  });

  test('setModel with confirmExpensive passes confirm_expensive_model=true',
      () async {
    final gw = ParityGateway();
    gw.responses['config.set'] = {'value': 'gpt-5'};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');
    await store.setModel('gpt-5', confirmExpensive: true);
    final c = gw.callFor('config.set')!;
    expect(c.$2['confirm_expensive_model'], true);
    expect(store.currentModel, 'gpt-5');
  });

  test('configSet with an empty gateway result falls back to the requested value',
      () async {
    final gw = ParityGateway();
    // No config.set response registered -> request() returns {}, so the
    // store must fall back to the value it asked for.
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    expect(await store.configSet('theme', 'light'), 'light');
  });

  test('configGet resolves the value from a bare-scalar or value-map result',
      () async {
    final gw = ParityGateway();
    gw.responses['config.get'] = {'value': 'dark'};
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    expect(await store.configGet('theme'), 'dark');
  });
}
