import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Issue #2: `/queue` must submit with `queued: true` so the gateway forces
/// queue mode (a "run after" message must never become a live correction).
/// Issue #3: `/compress` must acknowledge the START (before the request
/// returns), not only the finish toast.
///
/// A recording gateway captures the exact `prompt.submit` params and gates the
/// `session.compress` reply on a Completer so the test can observe the
/// acknowledgement in the in-flight window.

final _cfg = GatewayConfig(url: 'http://localhost:1');

class R35Gateway extends GatewayClient {
  R35Gateway() : super(_cfg);
  final responses = <String, Map<String, dynamic>>{};
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final _stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);

  /// Every `prompt.submit` request's params, in order.
  final List<Map<String, dynamic>> submits = [];
  /// Gate the `session.compress` reply so the test can hold it in flight.
  Completer<Map<String, dynamic>>? compressGate;

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
    if (responses.containsKey(method)) return responses[method]!;
    switch (method) {
      case 'prompt.submit':
        submits.add(Map<String, dynamic>.from(params));
        return {'status': 'queued'};
      case 'session.compress':
        if (compressGate != null) {
          // Hold the reply until the test releases it: the in-flight window.
          final g = compressGate!;
          return g.future;
        }
        return {'status': 'compressed', 'removed': 3};
      case 'session.create':
        return {'session_id': 'live-a'};
      case 'session.list':
        return {'sessions': const <Map<String, dynamic>>[]};
      case 'session.usage':
        return {'context_used': 1000, 'context_max': 128000};
      default:
        return <String, dynamic>{};
    }
  }

  /// Push a gateway event as the active session ('live-a', see _readyStore).
  void emit(String type, Map<String, dynamic> data,
          {String sid = 'live-a'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
    await _stateCtl.close();
  }
}

Future<(R35Gateway, ChatStore)> _readyStore(WidgetTester? t) async {
  final gw = R35Gateway();
  gw.responses['session.resume'] = {
    'session_id': 'live-a',
    'resumed': 'stored-a',
    'messages': const <Map<String, dynamic>>[
      {'role': 'user', 'text': 'hi', 'ts': 1.0},
      {'role': 'assistant', 'text': 'hello', 'ts': 2.0},
    ],
  };
  final store = ChatStore(config: _cfg, client: gw);
  await store.connect();
  // Give the store an active runtime session to send into.
  await store.resumeSession('stored-a');
  await Future<void>.delayed(const Duration(milliseconds: 10));
  return (gw, store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('issue #2: /queue forces queue mode', () {
    // Superseded by the client-side queue (round 41): /queue now holds the
    // message in the APP so it can be edited or dropped before it runs, and the
    // message is only submitted when the running turn ends. What this test
    // exists to protect - that a queued message is never applied as a live
    // correction - is asserted on that submission instead.
    test('/queue holds the message in the app while a turn runs', () async {
      final (gw, store) = await _readyStore(null);
      addTearDown(store.dispose);
      await store.send('a turn is already running');
      gw.responses['slash.exec'] = {
        'type': 'send',
        'message': 'focus on the brake pad depth',
        'output': '',
        'notice': '',
      };
      final before = gw.submits.length;
      await store.execSlashDispatch('/queue focus on the brake pad depth');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(gw.submits, hasLength(before),
          reason: 'a queued message is not sent while the turn runs');
      expect(store.queuedPrompts.map((q) => q.text),
          contains('focus on the brake pad depth'),
          reason: 'it waits in the app, where it can still be edited');
      expect(store.statusLine.toLowerCase(), contains('queued'));
    });

    test('the queued message is submitted with queued:true when the turn ends',
        () async {
      final (gw, store) = await _readyStore(null);
      addTearDown(store.dispose);
      await store.send('a turn is already running');
      gw.responses['slash.exec'] = {
        'type': 'send',
        'message': 'focus on the brake pad depth',
        'output': '',
        'notice': '',
      };
      await store.execSlashDispatch('/queue focus on the brake pad depth');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      gw.emit('message.complete', {'text': 'done'});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final queued = gw.submits.where((s) => s['queued'] == true).toList();
      expect(queued, hasLength(1),
          reason: 'the drained message must still force queue mode so it can '
              'never become a live correction');
      expect(queued.single['text'], 'focus on the brake pad depth');
    });

    test('/q (alias) queues the same way', () async {
      final (gw, store) = await _readyStore(null);
      addTearDown(store.dispose);
      gw.emit('message.start', {});
      gw.emit('message.delta', {'text': 'a turn is running'});
      gw.responses['slash.exec'] = {
        'type': 'send',
        'message': 'run the diagnostics',
        'output': '',
        'notice': '',
      };
      await store.execSlashDispatch('/q run the diagnostics');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(store.queuedPrompts.map((q) => q.text),
          contains('run the diagnostics'),
          reason: '/q is an alias of /queue');
    });

    test('a plain mid-turn send does NOT set queued', () async {
      final (gw, store) = await _readyStore(null);
      addTearDown(store.dispose);
      await store.send('plain mid-turn message');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(gw.submits, hasLength(1));
      expect(gw.submits.single.containsKey('queued'), false,
          reason: 'a plain send keeps the session busy mode, so it must not '
              'pass the queued flag');
    });

    test('a /skill kickoff does NOT force queue mode', () async {
      final (gw, store) = await _readyStore(null);
      addTearDown(store.dispose);
      gw.responses['slash.exec'] = {
        'type': 'skill',
        'message': 'do the thing',
        'output': '',
        'notice': '',
      };
      await store.execSlashDispatch('/my-skill do the thing');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(gw.submits, hasLength(1));
      expect(gw.submits.single.containsKey('queued'), false,
          reason: 'skill kickoffs follow the session busy mode, not the queue');
    });
  });

  group('issue #3: /compress acknowledges the start', () {
    test('a start notice fires BEFORE the request returns', () async {
      final (gw, store) = await _readyStore(null);
      addTearDown(store.dispose);

      final notices = <String>[];
      final sub = store.notices.listen(notices.add);

      // Hold the compress reply in flight.
      final gate = Completer<Map<String, dynamic>>();
      gw.compressGate = gate;

      final pending = store.compressSession();
      // The request is now in flight. The start notice must already be queued.
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(store.compressing, true,
          reason: 'the in-flight flag must be armed during the request');
      expect(notices, isNotEmpty,
          reason: 'a start acknowledgement must fire while the request is in '
              'flight, not only at completion');
      expect(notices.first, isNot(contains('Compressed')));

      // Now complete the request; the flag must disarm and a finish toast may
      // follow, but the start must have come first.
      gate.complete({'status': 'compressed', 'removed': 3});
      final result = await pending;
      expect(result, 'Compressed');
      expect(store.compressing, false,
          reason: 'the in-flight flag must disarm on completion');
      await sub.cancel();
    });

    test('the gateway compressing status cannot double-announce', () async {
      final (gw, store) = await _readyStore(null);
      addTearDown(store.dispose);

      final notices = <String>[];
      final sub = store.notices.listen(notices.add);
      addTearDown(sub.cancel);

      final gate = Completer<Map<String, dynamic>>();
      gw.compressGate = gate;
      unawaited(store.compressSession());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final firstCount = notices.length;
      expect(firstCount, 1, reason: 'exactly one start ack before the status');

      // The gateway now streams its own `compressing` status (4+ messages).
      // It must NOT add a second start notice.
      gw.pushed.add(GatewayEvent(
          type: 'status.update',
          sessionId: 'live-a',
          payload: {
            'kind': 'compressing',
            'name': 'compressing',
            'text': '⠋ compressing 6 messages (~1,234 tok)…'
          }));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(notices.length, firstCount,
          reason: 'the gateway status must not double-announce the start');
      // The status line DID pick up the gateway text for the pill.
      expect(store.statusLine, contains('compressing'));

      gate.complete({'status': 'compressed', 'removed': 3});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(store.compressing, false);
    });
  });
}
