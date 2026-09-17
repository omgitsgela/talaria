import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/screens/settings_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Fake gateway with a configurable live-session list, so the model-switch
/// target probe can be exercised honestly (a session that is absent from
/// `session.active_list` is exactly the case that used to pin nothing).
class SwitchGateway extends GatewayClient {
  SwitchGateway({this.liveSessions = const []})
      : super(GatewayConfig(url: 'http://gw.example.internal:9119'));

  List<Map<String, dynamic>> liveSessions;
  final List<String> calls = [];
  final List<Map<String, dynamic>> setModelCalls = [];
  final List<Map<String, dynamic>> submitted = [];

  Map<String, dynamic> setModelResponse = {
    'key': 'model',
    'value': 'new-model',
    'warning': '',
    'confirm_required': false,
    'scope': 'session',
  };

  /// When set, `session.resume` waits on it, which keeps the store in its
  /// loading state for as long as the test wants.
  Completer<void>? resumeGate;
  int resumeCount = 0;

  /// When true, `session.resume` fails: the stored conversation is gone.
  bool failResume = false;

  final _pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final _stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => _pushed.stream;
  @override
  Stream<GwConnectionState> get stateChanges => _stateCtl.stream;

  @override
  Future<void> connect({bool isReconnect = false}) async {
    _stateCtl.add(GwConnectionState.open);
  }

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    calls.add(method);
    switch (method) {
      case 'session.resume':
        resumeCount++;
        final gate = resumeGate;
        if (gate != null) await gate.future;
        if (failResume) throw GatewayError('session not found', code: 4007);
        return {
          'session_id': 'rt-$resumeCount',
          'resumed': params['session_id'],
          'messages': [
            {'role': 'assistant', 'text': 'loaded from the gateway'}
          ],
          'running': false,
          'info': {
            'model': 'old-model',
            'provider': 'llamacpp-qwen38',
            'reasoning_effort': 'medium',
          },
        };
      case 'session.active_list':
        return {'sessions': liveSessions};
      case 'session.history':
        return {'messages': const <Map<String, dynamic>>[]};
      case 'session.usage':
        return {'context_used': 24500, 'context_max': 128000, 'context_percent': 19};
      case 'config.set':
        if (params['key'] == 'model') setModelCalls.add(Map<String, dynamic>.of(params));
        return setModelResponse;
      case 'config.get':
        return {'value': 'old-model'};
      case 'slash.exec':
        return {'output': 'No active goal. Set one with /goal <text>.'};
      case 'model.options':
        return {
          'providers': [
            {
              'slug': 'llamacpp-qwen38',
              'name': 'Local (llama.cpp)',
              'models': [
                {'slug': 'alpha-model', 'label': 'alpha-model', 'authenticated': true},
                {'slug': 'beta-model', 'label': 'beta-model', 'authenticated': true},
              ],
            },
          ],
        };
      default:
        return {};
    }
  }

  void emit(String type, Map<String, dynamic> data, {String sid = 'rt-1'}) =>
      _pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await _pushed.close();
    await _stateCtl.close();
  }
}

final _cfg = GatewayConfig(url: 'http://gw.example.internal:9119');

Future<ChatStore> _open(SwitchGateway gw) async {
  final store = ChatStore(config: _cfg, client: gw);
  await store.connect();
  return store;
}

Widget _themed(Widget child) => MaterialApp(home: child);

void _phoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1260, 2700);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('loading an existing conversation', () {
    test('awaitingTranscript is true while the resume is in flight, then false',
        () async {
      final gw = SwitchGateway()..resumeGate = Completer<void>();
      final store = await _open(gw);
      addTearDown(store.dispose);

      final load = store.resumeSession('stored-1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(store.loadingSession, isTrue);
      expect(store.messages, isEmpty);
      expect(store.awaitingTranscript, isTrue,
          reason: 'an empty transcript mid-load is not a new conversation');

      gw.resumeGate!.complete();
      await load;
      expect(store.awaitingTranscript, isFalse);
      expect(store.messages, isNotEmpty);
    });

    test('a settled empty transcript is not treated as loading', () async {
      final gw = SwitchGateway();
      final store = await _open(gw);
      addTearDown(store.dispose);
      expect(store.awaitingTranscript, isFalse);
      await store.resumeSession('stored-1');
      // history() answered with no rows, so the view stays empty — but nothing
      // is loading any more, and the deferred pull owns the retry.
      expect(store.loadingSession, isFalse);
    });

    testWidgets('the view shows a loading state, never the new-chat empty state',
        (tester) async {
      _phoneSurface(tester);
      final gw = SwitchGateway()..resumeGate = Completer<void>();
      final store = await _open(gw);
      addTearDown(store.dispose);

      unawaited(store.resumeSession('stored-1'));
      await tester.pumpWidget(_themed(Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump(const Duration(milliseconds: 80));

      // The reported bug: a long conversation looked like a brand new one.
      expect(find.text('Loading conversation…'), findsOneWidget);
      expect(find.text('Ask Hermes anything'), findsNothing);
      expect(find.text('Start a new chat or open a past session from the menu.'),
          findsNothing);

      gw.resumeGate!.complete();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.text('Loading conversation…'), findsNothing);
      expect(find.text('loaded from the gateway'), findsOneWidget);
    });
  });

  group('model switch targeting', () {
    test('sends the switch only when the target is live', () async {
      final gw = SwitchGateway();
      final store = await _open(gw);
      addTearDown(store.dispose);
      await store.resumeSession('stored-1');
      expect(store.activeSessionId, 'rt-1');
      gw.liveSessions = [
        {'id': 'rt-1', 'session_id': 'rt-1'}
      ];

      final res = await store.setModel('new-model');
      expect(res.status, SetModelStatus.success);
      expect(gw.setModelCalls.single['session_id'], 'rt-1');
      expect(gw.setModelCalls.single['value'], 'new-model');
      expect(store.currentModel, 'new-model');
    });

    test('refuses the switch when the session cannot be made live', () async {
      final gw = SwitchGateway(); // active_list is always empty
      final store = await _open(gw);
      addTearDown(store.dispose);
      await store.resumeSession('stored-1');
      // The stored conversation is gone on the gateway, so the re-attach cannot
      // produce a fresh runtime id to pin the switch to.
      gw.failResume = true;
      final modelBefore = store.currentModel;
      gw.setModelCalls.clear();

      final res = await store.setModel('new-model');

      expect(res.status, SetModelStatus.error);
      expect(gw.setModelCalls, isEmpty,
          reason: 'a switch sent against an unresolvable session is answered '
              'with a success envelope while pinning nothing');
      expect(store.currentModel, modelBefore,
          reason: 'the header must not claim a model the gateway never applied');
      expect(store.statusLine, contains('not live on the gateway'));
    });

    test('waits for an in-flight load before deciding, then applies', () async {
      final gw = SwitchGateway()..resumeGate = Completer<void>();
      final store = await _open(gw);
      addTearDown(store.dispose);

      store.resetSettleWaitCountForTest();
      unawaited(store.resumeSession('stored-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The pick lands while the conversation is still loading, which is the
      // race that used to send the switch against the outgoing runtime id.
      final pending = store.setModel('new-model');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(gw.setModelCalls, isEmpty, reason: 'must not fire mid-load');

      gw.liveSessions = [
        {'id': 'rt-1', 'session_id': 'rt-1'}
      ];
      gw.resumeGate!.complete();
      final res = await pending;

      expect(res.status, SetModelStatus.success);
      expect(gw.setModelCalls.single['session_id'], 'rt-1',
          reason: 'the switch must follow the load to the settled runtime id');
      expect(store.settleWaitCountForTest, 1,
          reason: 'the probe waited for the load to settle');
      expect(gw.resumeCount, 1,
          reason: 'no throwaway draft session for a conversation that is loading');
    });

    test('a deferred switch is reported as deferred, not applied', () async {
      final gw = SwitchGateway();
      final store = await _open(gw);
      addTearDown(store.dispose);
      await store.resumeSession('stored-1');
      gw.liveSessions = [
        {'id': 'rt-1', 'session_id': 'rt-1'}
      ];
      gw.setModelResponse = {
        'key': 'model',
        'value': 'pending-model',
        'warning': '',
        'confirm_required': false,
        'scope': 'session',
        'deferred': true,
      };

      final res = await store.setModel('pending-model');

      expect(res.status, SetModelStatus.deferred);
      expect(res.isSuccess, isFalse);
      expect(res.message, contains('applies from the next turn'));
      expect(store.statusLine, contains('applies from the next turn'));
    });

    test('a warning means nothing was applied, and says so', () async {
      final gw = SwitchGateway();
      final store = await _open(gw);
      addTearDown(store.dispose);
      await store.resumeSession('stored-1');
      final modelBefore = store.currentModel;
      gw.liveSessions = [
        {'id': 'rt-1', 'session_id': 'rt-1'}
      ];
      gw.setModelResponse = {
        'key': 'model',
        'value': 'unavailable-model',
        'warning': 'model not authenticated on this gateway',
        'confirm_required': false,
        'scope': 'session',
      };

      final res = await store.setModel('unavailable-model');

      expect(res.status, SetModelStatus.error);
      expect(res.message, contains('not authenticated'));
      expect(store.currentModel, modelBefore);
    });
  });

  group('model picker search', () {
    testWidgets('no matches keeps the search field and offers a way back',
        (tester) async {
      _phoneSurface(tester);
      final gw = SwitchGateway();
      final store = await _open(gw);
      addTearDown(store.dispose);
      await tester.pumpWidget(_themed(SettingsScreen(store: store)));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 60));

      final field = find.widgetWithText(TextField, 'Search models…');
      expect(field, findsOneWidget);
      await tester.enterText(field, 'zzzz-nothing-matches');
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.text('No models match “zzzz-nothing-matches”.'), findsOneWidget);
      // The reported bug: the field vanished with the results, so the query
      // that produced the empty result could not be corrected.
      expect(find.widgetWithText(TextField, 'zzzz-nothing-matches'), findsOneWidget);
      expect(find.text('Clear search'), findsOneWidget);

      await tester.tap(find.text('Clear search'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.text('No models match “zzzz-nothing-matches”.'), findsNothing);
      expect(find.textContaining('alpha-model'), findsWidgets);
    });
  });
}
