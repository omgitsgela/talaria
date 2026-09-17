import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 18 (2026-09-14): a conversation that finished a turn while the phone
/// was backgrounded came back broken — the socket reconnected (header says
/// connected) but the transcript kept a stale runtime session id, so
///   * the bottom showed "Connection lost — reconnecting…" forever, and
///   * sending failed with `session not found` (4001).
///
/// Gateway contract (tui_gateway/server.py `_sess_nowait`): a runtime id is
/// DETACHED when its client's WebSocket drops and then orphan-reaped; a stale
/// id gets 4001 "session not found" and "the client should session.resume the
/// STORED id". These tests pin that recovery.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class R18Gateway extends GatewayClient {
  R18Gateway() : super(_cfg);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];
  final deleted = <String>{};

  /// Runtime ids handed out by successive session.resume calls.
  int _runtimeSeq = 0;
  /// Fail the FIRST prompt.submit with 4001 (stale runtime), then succeed.
  bool failFirstSubmitWith4001 = false;
  int submitCount = 0;
  /// Live rows returned by session.active_list.
  List<Map<String, dynamic>> activeRows = const [];

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

  /// The fresh runtime id the last resume handed out.
  String get lastRuntime => 'rt-$_runtimeSeq';

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    calls.add((method, params));
    switch (method) {
      case 'session.resume':
        _runtimeSeq++;
        return {
          'session_id': lastRuntime,
          'resumed': params['session_id'],
          'messages': [
            {'role': 'user', 'text': 'stored question'},
            {'role': 'assistant', 'text': 'stored answer'},
          ],
          'info': {'model': 'test-model'},
        };
      case 'session.active_list':
        return {'sessions': activeRows};
      case 'session.list':
        return {'sessions': const <Map<String, dynamic>>[]};
      case 'prompt.submit':
        submitCount++;
        if (failFirstSubmitWith4001 && submitCount == 1) {
          throw GatewayError('session not found', code: 4001);
        }
        return {'status': 'streaming'};
      default:
        return {};
    }
  }

  int countOf(String method) => calls.where((c) => c.$1 == method).length;

  void emit(String type, Map<String, dynamic> data, {String sid = ''}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
    await stateCtl.close();
  }
}

/// Let queued microtasks/timers in the store settle.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('stale runtime session recovery (round 18)', () {
    test('a send that hits 4001 re-resumes the stored id and lands the message',
        () async {
      final gw = R18Gateway()..failFirstSubmitWith4001 = true;
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');
      expect(store.activeSessionId, 'rt-1');
      expect(gw.countOf('session.resume'), 1);

      final ok = await store.send('hello there');

      expect(ok, isTrue,
          reason: 'the documented 4001 recovery must deliver the message');
      expect(gw.countOf('prompt.submit'), 2,
          reason: 'one rejected submit + one retry');
      expect(gw.countOf('session.resume'), 2,
          reason: 'the retry must be preceded by a session.resume of the '
              'STORED id');
      expect(store.activeSessionId, 'rt-2',
          reason: 'the conversation is re-attached under a fresh runtime id');
      // The rehydration drops the optimistic row, so it must be re-added for
      // the retry — and exactly once.
      expect(store.messages.where((m) => m.text == 'hello there').length, 1,
          reason: 'the user message must appear exactly once');
      expect(store.messages.last.text, 'hello there');
      expect(store.streaming, isTrue);
      expect(store.statusLine, isNot(contains('session not found')));
    });

    test('a send that fails for a non-4001 reason still reports failure and '
        'leaves no ghost', () async {
      final gw = R18Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');
      // Reject every submit with a real error.
      gw.failFirstSubmitWith4001 = false;
      final failing = _AlwaysFailGateway();
      final store2 = ChatStore(config: _cfg, client: failing);
      addTearDown(store2.dispose);
      await store2.connect();
      await store2.resumeSession('stored-x');

      final ok = await store2.send('doomed message');

      expect(ok, isFalse);
      expect(store2.messages.where((m) => m.text == 'doomed message'), isEmpty,
          reason: 'a failed send must not leave a ghost row');
      expect(store2.streaming, isFalse);
      expect(store2.statusLine, contains('gateway exploded'));
      expect(failing.countOf('session.resume'), 1,
          reason: 'no recovery may be attempted for a non-4001 failure');
    });

    test('a conversation missing from the live table is silently re-attached',
        () async {
      final gw = R18Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');
      expect(store.activeSessionId, 'rt-1');
      expect(store.messages, isNotEmpty);

      // The gateway no longer holds this runtime (reaped after a WS detach):
      // the live table has no row for it.
      gw.activeRows = const [];
      store.resetStatusPollThrottleForTest();
      gw.emit('sessions.changed', const {});
      await _settle();

      expect(gw.countOf('session.resume'), 2,
          reason: 'the reconcile must re-attach the stored conversation');
      expect(store.activeSessionId, 'rt-2');
    });

    test('the reconnect banner is cleared once the socket is back', () async {
      final gw = R18Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();

      gw.stateCtl.add(GwConnectionState.reconnecting);
      await _settle();
      expect(store.statusLine, contains('Connection lost'),
          reason: 'the banner is expected while the socket is down');

      gw.stateCtl.add(GwConnectionState.open);
      await _settle();
      expect(store.statusLine, isEmpty,
          reason: 'a recovered socket must not leave the reconnect banner '
              'under a "connected" header');
    });
  });
}

/// A gateway whose prompt.submit always fails with a non-recoverable error.
class _AlwaysFailGateway extends R18Gateway {
  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    if (method == 'prompt.submit') {
      calls.add((method, params));
      throw GatewayError('gateway exploded', code: 5000);
    }
    return super.request(method, params, timeoutMs);
  }
}
