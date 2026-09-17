import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 17 (2026-09-14): conversation delete did nothing.
///
/// Root causes (verified against tui_gateway/methods_session.py):
/// 1. The old guard compared the STORED key against `_activeSessionId`
///    (the RUNTIME sid) — two different id spaces that never match, so
///    deleting the conversation you were viewing always proceeded straight
///    to the gateway…
/// 2. …and the gateway refuses to delete a LIVE session (4023 "cannot
///    delete an active session" — FK trips on the agent's next flush), so
///    the viewable conversation was exactly the one that could never be
///    deleted. The desktop's reference flow closes the runtime session
///    first (session.close), resets to a fresh draft, THEN deletes.
/// 3. The old catch swallowed every failure silently (`catch (_) {}`),
///    so the button looked dead no matter what happened.
///
/// Fix: `deleteSession` returns a bool, closes the runtime + resets the
/// local view when the target is the conversation on screen, and surfaces
/// failures through the status line.

final _cfg = GatewayConfig(url: 'http://localhost:1');

class R17Gateway extends GatewayClient {
  R17Gateway() : super(_cfg);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final _stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];
  final deleted = <String>{};
  bool refuseDelete = false;

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
    switch (method) {
      case 'session.resume':
        return {
          'session_id': 'rt-${params['session_id']}',
          'resumed': params['session_id'],
          'messages': <Map<String, dynamic>>[],
          'info': {'model': 'test-model'},
        };
      case 'session.list':
        // Model the gateway's DB: a deleted session no longer lists.
        return {
          'sessions': [
            {'id': 'kept', 'title': 'Kept chat', 'started_at': 1.0},
            {'id': 'doomed', 'title': 'Doomed chat', 'started_at': 2.0},
          ].where((r) => !deleted.contains(r['id'])).toList()
        };
      case 'session.delete':
        if (refuseDelete) {
          throw GatewayError('cannot delete an active session', code: 4023);
        }
        deleted.add(params['session_id'] as String);
        return {'deleted': params['session_id']};
      default:
        return {};
    }
  }

  @override
  Future<void> dispose() async {
    await pushed.close();
    await _stateCtl.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('conversation delete (round 17)', () {
    test('deleting an inactive conversation removes the row', () async {
      final gw = R17Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.loadSessions();
      expect(store.sessions.map((s) => s.id), containsAll(['kept', 'doomed']));

      final ok = await store.deleteSession('doomed');

      expect(ok, isTrue, reason: 'a landing delete must report success');
      expect(store.sessions.map((s) => s.id), isNot(contains('doomed')));
      expect(store.sessions.map((s) => s.id), contains('kept'));
      // No runtime was on screen: no session.close should have been issued.
      expect(gw.calls.where((c) => c.$1 == 'session.close'), isEmpty);
    });

    test('deleting the conversation on screen closes its runtime first, '
        'resets the view, and still deletes', () async {
      final gw = R17Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('doomed');
      expect(store.activeSessionId, isNotNull,
          reason: 'resume must establish a runtime session id');
      final runtime = store.activeSessionId!;

      final ok = await store.deleteSession('doomed');

      expect(ok, isTrue);
      // The runtime was finalized BEFORE the delete — the only way the
      // gateway will accept the deletion of a live session.
      final closeCall =
          gw.calls.firstWhere((c) => c.$1 == 'session.close',
              orElse: () => ('', <String, dynamic>{}));
      expect(closeCall.$1, 'session.close');
      expect(closeCall.$2['session_id'], runtime,
          reason: 'session.close must target the RUNTIME sid, not the stored key');
      final order = gw.calls.map((c) => c.$1).toList();
      expect(order.indexOf('session.close') < order.indexOf('session.delete'),
          isTrue,
          reason: 'close must precede delete');
      // The local view was reset to a fresh draft (nothing half-deleted
      // left on screen).
      expect(store.activeSessionId, isNull);
      expect(store.activeStoredSessionId, isNull);
      expect(store.messages, isEmpty);
    });

    test('a refused delete returns false and surfaces a clean error',
        () async {
      final gw = R17Gateway()..refuseDelete = true;
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.loadSessions();

      final ok = await store.deleteSession('doomed');

      expect(ok, isFalse,
          reason: 'a gateway-refused delete must report failure');
      // The row must NOT be optimistically dropped on failure.
      expect(store.sessions.map((s) => s.id), contains('doomed'));
      expect(store.statusLine, contains('cannot delete an active session'),
          reason: 'the failure must surface to the user (no silent no-op)');
      expect(store.statusLine, isNot(contains('GatewayError(')),
          reason: 'the error wrapper must be stripped');
    });
  });
}
