import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/models/context_usage.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Context-window readout in the app bar (Round 27).
///
/// The gateway puts current occupancy in its usage payload (`_get_usage` in
/// `tui_gateway/server.py`): nested under `usage` on `session.info` and
/// `message.complete`, flat from `session.usage`. It deliberately omits
/// `context_used`/`context_max` when the context engine cannot measure
/// occupancy, so an unknown reading must render NOTHING rather than 0%.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class R27Gateway extends GatewayClient {
  R27Gateway() : super(_cfg);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];

  /// What `session.usage` answers.
  Map<String, dynamic> usageReply = const {};

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
    calls.add((method, params));
    switch (method) {
      case 'session.resume':
        return {
          'session_id': 'rt-1',
          'resumed': params['session_id'],
          'messages': const <Map<String, dynamic>>[],
          'info': {'model': 'test-model'},
        };
      case 'session.usage':
        return usageReply;
      case 'session.list':
        return {'sessions': const <Map<String, dynamic>>[]};
      case 'session.active_list':
        return {'sessions': const <Map<String, dynamic>>[]};
      default:
        return {};
    }
  }

  int countOf(String method) => calls.where((c) => c.$1 == method).length;

  void emit(String type, Map<String, dynamic> data, {String sid = 'rt-1'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
    await stateCtl.close();
  }
}

/// The gateway's real shape for a measurable window.
Map<String, dynamic> _usage({int used = 24500, int max = 128000}) => {
      'model': 'test-model',
      'input': used,
      'output': 10,
      'total': used + 10,
      'calls': 3,
      'context_used': used,
      'context_max': max,
      'context_percent': ((used / max) * 100).round(),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ContextUsage parsing (round 27)', () {
    test('formats token counts the way the app bar wants them', () {
      expect(formatTokenCount(0), '0');
      expect(formatTokenCount(950), '950');
      expect(formatTokenCount(12400), '12.4k');
      expect(formatTokenCount(24500), '24.5k');
      expect(formatTokenCount(128000), '128k');
      expect(formatTokenCount(1500000), '1.5m');
    });

    test('reads a real reading, deriving the percent when absent', () {
      final u = ContextUsage.fromUsage({'context_used': 32000, 'context_max': 128000});
      expect(u.isKnown, isTrue);
      expect(u.used, 32000);
      expect(u.max, 128000);
      expect(u.percent, 25);
      expect(u.label, '32k/128k');
      expect(u.description, 'Context: 32k of 128k (25%)');
    });

    test('shows only the used count when the window size is unknown', () {
      final u = ContextUsage.fromUsage({'context_used': 9000});
      expect(u.label, '9k');
      expect(u.description, 'Context: 9k');
    });

    test('an unmeasurable window stays unknown instead of showing 0%', () {
      // The gateway omits the fields entirely for an engine that cannot report
      // occupancy, and clamps its -1 "compression just ran" sentinel to 0.
      expect(ContextUsage.fromUsage(const {}).isKnown, isFalse);
      expect(ContextUsage.fromUsage(const {}).label, isNull);
      expect(ContextUsage.fromUsage({'context_used': 0, 'context_max': 128000}).isKnown, isFalse);
      expect(ContextUsage.fromUsage({'context_used': -1, 'context_max': 128000}).isKnown,
          isFalse);
      expect(ContextUsage.fromUsage({'context_used': 500, 'context_max': 0}).label, '500');
    });

    test('tolerates JSON-shaped strings and clamps a wild percent', () {
      final u = ContextUsage.fromUsage(
          {'context_used': '12000', 'context_max': '128000', 'context_percent': 900});
      expect(u.label, '12k/128k');
      expect(u.percent, 100, reason: 'a bogus percent is clamped, not printed raw');
    });
  });

  group('the store tracks the live reading (round 27)', () {
    test('session.info carries the reading', () async {
      final gw = R27Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');
      expect(store.contextLabel, isNull, reason: 'nothing reported yet');

      gw.emit('session.info', {'model': 'test-model', 'usage': _usage()});

      expect(store.contextLabel, '24.5k/128k');
      expect(store.contextUsage.percent, 19);
    });

    test('message.complete carries the turn-end reading', () async {
      final gw = R27Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');

      gw.emit('message.start', const {});
      gw.emit('message.complete',
          {'text': 'done', 'usage': _usage(used: 64000, max: 128000)});

      expect(store.contextLabel, '64k/128k');
    });

    test('a resume pulls the reading before the first turn ends', () async {
      final gw = R27Gateway()..usageReply = _usage(used: 8000, max: 200000);
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(gw.countOf('session.usage'), 1);
      expect(store.contextLabel, '8k/200k');
    });

    test('a flat session.usage event is accepted too', () async {
      final gw = R27Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');

      gw.emit('session.usage', _usage(used: 1000, max: 4000));

      expect(store.contextLabel, '1k/4k');
    });

    test('switching conversations clears the readout', () async {
      final gw = R27Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('stored-x');
      gw.emit('session.info', {'model': 'test-model', 'usage': _usage()});
      expect(store.contextLabel, isNotNull);

      // A new conversation is a different context window.
      gw.usageReply = const {};
      await store.createSession();

      expect(store.contextLabel, isNull);
    });
  });

  group('the app bar shows it (round 27)', () {
    testWidgets('next to the model name, and hidden while unknown',
        (tester) async {
      tester.view.physicalSize = const Size(1260, 2700);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final gw = R27Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();
      await store.resumeSession('stored-x');
      await tester.pump();

      expect(find.text('24.5k/128k'), findsNothing,
          reason: 'no reading yet: the app bar must not invent one');

      gw.emit('session.info', {'model': 'test-model', 'usage': _usage()});
      await tester.pump();

      expect(find.text('test-model'), findsOneWidget);
      expect(find.text('24.5k/128k'), findsOneWidget,
          reason: 'the readout sits beside the model name');
    });

    testWidgets('a narrow phone shrinks the row instead of overflowing',
        (tester) async {
      // 360dp wide: the three buttons, the model name, the readout and the
      // status pill together exceed the bar, so the readout must ellipsize.
      // A RenderFlex overflow is reported as a test error, which is the point.
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final gw = R27Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();
      await store.resumeSession('stored-x');
      await tester.pump();

      gw.emit('session.info', {'model': 'deepseek-flash', 'usage': _usage()});
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: 'the app bar must not overflow on a 360dp phone');
      expect(store.contextLabel, '24.5k/128k',
          reason: 'the value is tracked even when it has to be clipped');
    });
  });
}
