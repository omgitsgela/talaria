import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/screens/settings_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

final config = GatewayConfig(url: 'http://localhost:1');

/// Fake gateway that records RPC calls, allows per-method overrides, and can
/// drive connection-state changes (so the store's reconnect path is testable).
class StoreGateway extends GatewayClient {
  StoreGateway() : super(config);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];
  final _stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);
  FutureOr<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
      handler;
  int connectCalls = 0;
  bool closeCalled = false;
  bool disposeCalled = false;

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => pushed.stream;
  @override
  Stream<GwConnectionState> get stateChanges => _stateCtl.stream;
  @override
  Future<void> connect({bool isReconnect = false}) async {
    connectCalls++;
    _stateCtl.add(GwConnectionState.open);
  }

  @override
  void close() {
    closeCalled = true;
    _stateCtl.add(GwConnectionState.closed);
  }

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    calls.add((method, params));
    if (handler != null) {
      final h = await handler!(method, params);
      if (h.isNotEmpty) return h;
    }
    return switch (method) {
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'session.create' => {'session_id': 'live-fresh'},
      'session.resume' => {
          'session_id': 'live-${params['session_id']}',
          'resumed': params['session_id'],
          'messages': const <Map<String, dynamic>>[],
          'info': const <String, dynamic>{'model': 'm'}
        },
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data,
          {String sid = 'live-fresh'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));
  void emitState(GwConnectionState s) => _stateCtl.add(s);
  bool called(String m) => calls.any((c) => c.$1 == m);
  int count(String m) => calls.where((c) => c.$1 == m).length;

  @override
  Future<void> dispose() async {
    disposeCalled = true;
    await pushed.close();
    await _stateCtl.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── Bug 1: launch opens a NEW conversation ─────────────────────────

  test('connect() starts a fresh conversation, not the most recent', () async {
    final gw = StoreGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    await store.connect();

    expect(store.activeSessionId, 'live-fresh',
        reason: 'a brand-new session must be created on connect');
    expect(store.messages, isEmpty,
        reason: 'no transcript may be hydrated on first launch');
    expect(gw.called('session.create'), isTrue);
    expect(gw.called('session.most_recent'), isFalse,
        reason: 'must not query the most-recent stored session');
    expect(gw.called('session.resume'), isFalse,
        reason: 'must not auto-resume a stored session on launch');
  });

  test('connect() with a create that returns no id falls back to a draft',
      () async {
    final gw = StoreGateway();
    gw.handler = (m, p) {
      if (m == 'session.create') return {'session_id': null};
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    await store.connect();

    expect(store.activeSessionId, isNull,
        reason: 'no usable session id -> local draft');
    expect(store.messages, isEmpty);
  });

  // ── Bug 2: reconnecting must NOT re-open the old conversation ──────

  test(
      'a background reconnect preserves the active session and does not '
      're-resume', () async {
    final gw = StoreGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    // Establish a live conversation first.
    await store.resumeSession('a');
    expect(store.activeSessionId, 'live-a');
    final resumesBefore = gw.count('session.resume');

    // The socket drops (app backgrounded) and recovers.
    gw.emitState(GwConnectionState.reconnecting);
    gw.emitState(GwConnectionState.open);
    await pumpEventQueue();

    expect(store.activeSessionId, 'live-a',
        reason: 'recovery must not swap the active conversation');
    expect(gw.count('session.resume'), resumesBefore,
        reason: 'recovery must not issue another session.resume');
    expect(gw.called('session.list'), isTrue,
        reason: 'the roster should still refresh on recovery');
  });

  // ── Bug 3: the socket keep-alive lives for the whole connection ────

  group('background keep-alive', () {
    final fgCalls = <String>[];
    const channel = MethodChannel('talaria/foreground');

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      fgCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        fgCalls.add(call.method);
        return true;
      });
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('service starts on connect, survives a turn ending, stops on close',
        () async {
      final gw = StoreGateway();
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);

      await store.connect();
      await pumpEventQueue();
      expect(fgCalls, contains('start'),
          reason:
              'an idle backgrounded socket needs a keep-alive from connect');
      expect(fgCalls.where((c) => c == 'stop'), isEmpty,
          reason: 'nothing has stopped it yet');

      // Run a full turn in the background.
      await store.send('hello');
      gw.emit('message.complete', {'text': 'hi there'});
      await pumpEventQueue();
      expect(store.streaming, isFalse, reason: 'turn should have finished');
      expect(fgCalls.where((c) => c == 'stop'), isEmpty,
          reason: 'turn end must NOT drop the keep-alive (only an explicit '
              'close does)');

      // An explicit close DOES drop the keep-alive.
      gw.emitState(GwConnectionState.closed);
      await pumpEventQueue();
      expect(fgCalls, contains('stop'),
          reason: 'close must stop the foreground service');
    });

    test('a transient dial error during reconnect does not stop the service',
        () async {
      final gw = StoreGateway();
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);

      await store.connect();
      await pumpEventQueue();
      expect(fgCalls, contains('start'));

      // The client reports a transient dial failure (auto-retrying) then
      // recovers. The keep-alive must stay alive across the error so the
      // retry can recover the socket in the background.
      gw.emitState(GwConnectionState.error);
      await pumpEventQueue();
      expect(fgCalls.where((c) => c == 'stop'), isEmpty,
          reason: 'a transient error must not kill the keep-alive');

      gw.emitState(GwConnectionState.open);
      await pumpEventQueue();
      expect(fgCalls.where((c) => c == 'stop'), isEmpty);
    });
  });

  // ── Bug 4: provider categories in the model picker ─────────────────

  test('providerGroups groups by provider, pins current first, keeps order',
      () async {
    final gw = StoreGateway();
    gw.handler = (m, p) {
      if (m == 'model.options') {
        return {
          'model': 'openai/gpt-4o',
          'providers': [
            {
              'slug': 'anthropic',
              'name': 'Anthropic',
              'is_current': false,
              'authenticated': true,
              'models': ['claude-3.5-sonnet']
            },
            {
              'slug': 'openai',
              'name': 'OpenAI',
              'is_current': true,
              'authenticated': true,
              'models': ['gpt-4o', 'gpt-4o-mini']
            },
            {
              'slug': 'custom:lab',
              'name': 'Custom Lab',
              'is_current': false,
              'authenticated': false,
              'models': ['vendor/model-v1']
            },
          ],
        };
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.loadModels();

    final groups = store.providerGroups;
    expect(groups.map((g) => g.slug).toList(),
        ['openai', 'anthropic', 'custom:lab'],
        reason: 'current provider first, then first-seen order for the rest');
    expect(groups.firstWhere((g) => g.slug == 'openai').models.length, 2);
    expect(groups.firstWhere((g) => g.slug == 'custom:lab').name, 'Custom Lab',
        reason: 'the provider display name is captured from the gateway');
  });

  testWidgets('model picker shows per-provider categories and a search field',
      (tester) async {
    final gw = StoreGateway();
    gw.handler = (m, p) {
      if (m == 'model.options') {
        return {
          'model': 'openai/gpt-4o',
          'providers': [
            {
              'slug': 'openai',
              'name': 'OpenAI',
              'is_current': true,
              'authenticated': true,
              'models': ['gpt-4o', 'gpt-4o-mini']
            },
            {
              'slug': 'anthropic',
              'name': 'Anthropic',
              'is_current': false,
              'authenticated': true,
              'models': ['claude-opus-4']
            },
          ],
        };
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    // Each provider is a category header; there is a search field.
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('Anthropic'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets,
        reason: 'the picker must offer a search field');

    // Searching filters by slug/provider: 'claude' keeps Anthropic and hides
    // the OpenAI group (whose models do not match).
    await tester.enterText(find.byType(TextField).first, 'claude');
    await tester.pumpAndSettle();
    expect(find.text('Anthropic'), findsOneWidget);
    expect(find.text('claude-opus-4'), findsOneWidget);
    expect(find.text('OpenAI'), isNot(findsWidgets),
        reason: 'non-matching provider group should be filtered out');
    expect(find.text('gpt-4o'), isNot(findsWidgets));
  });

  testWidgets('selecting a model in a category sends slug + --provider flag',
      (tester) async {
    final gw = StoreGateway();
    final modelCalls = <Map<String, dynamic>>[];
    gw.handler = (m, p) {
      if (m == 'model.options') {
        return {
          'model': 'openai/gpt-4o',
          'providers': [
            {
              'slug': 'openai',
              'name': 'OpenAI',
              'is_current': true,
              'authenticated': true,
              'models': ['gpt-4o']
            },
            {
              'slug': 'custom:lab',
              'name': 'Custom Lab',
              'is_current': false,
              'authenticated': true,
              'models': ['vendor/model-v1']
            },
          ],
        };
      }
      if (m == 'config.set' && p['key'] == 'model') {
        modelCalls.add(p);
        return {'value': p['value']};
      }
      if (m == 'config.get') return {'value': 'fast'};
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    // Pick the custom provider's model (preserves the slash in the slug).
    await tester.tap(find.text('vendor/model-v1'));
    await tester.pumpAndSettle();

    expect(modelCalls, isNotEmpty);
    expect(modelCalls.last['value'], 'vendor/model-v1 --provider custom:lab',
        reason: 'model id preserved verbatim, provider routed via --provider');
  });

  // ── Bug 1 follow-up: checkmark moves after an in-app switch ────────

  testWidgets('checkmark moves to the newly selected model after a switch',
      (tester) async {
    final gw = StoreGateway();
    gw.handler = (m, p) {
      if (m == 'model.options') {
        return {
          'model': 'openai/gpt-4o',
          'provider': 'openai',
          'providers': [
            {
              'slug': 'openai',
              'name': 'OpenAI',
              'is_current': true,
              'authenticated': true,
              'models': ['gpt-4o', 'gpt-4o-mini']
            },
            {
              'slug': 'anthropic',
              'name': 'Anthropic',
              'is_current': false,
              'authenticated': true,
              'models': ['claude-opus-4']
            },
          ],
        };
      }
      if (m == 'config.set' && p['key'] == 'model') {
        return {'value': p['value']};
      }
      if (m == 'config.get') return {'value': 'fast'};
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    // gpt-4o starts as current (the gateway's top-level model).
    expect(
        store
            .modelIsCurrent(store.models.firstWhere((m) => m.slug == 'gpt-4o')),
        isTrue);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    // Pick claude-opus-4 — the checkmark must move, and the sent value
    // must keep the slug as-is with the --provider flag.
    await tester.tap(find.text('claude-opus-4'));
    await tester.pumpAndSettle();

    final call = gw.calls.lastWhere((c) => c.$1 == 'config.set');
    expect(call.$2['value'], 'claude-opus-4 --provider anthropic');

    // Live identity updated: the old model is unselected, the new model
    // is selected, and the UI re-reflects that.
    expect(store.currentModelSlug, 'claude-opus-4');
    expect(store.currentModelProvider, 'anthropic');
    expect(
        store
            .modelIsCurrent(store.models.firstWhere((m) => m.slug == 'gpt-4o')),
        isFalse);
    expect(
        store.modelIsCurrent(
            store.models.firstWhere((m) => m.slug == 'claude-opus-4')),
        isTrue);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  // ── Bookmark models + persisted collapse state ─────────────────────

  testWidgets('bookmarked models pin to the top and collapse state works',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final gw = StoreGateway();
    gw.handler = (m, p) {
      if (m == 'model.options') {
        return {
          'model': 'openai/gpt-4o',
          'provider': 'openai',
          'providers': [
            {
              'slug': 'openai',
              'name': 'OpenAI',
              'is_current': true,
              'authenticated': true,
              'models': ['gpt-4o', 'gpt-4o-mini']
            },
            {
              'slug': 'anthropic',
              'name': 'Anthropic',
              'is_current': false,
              'authenticated': true,
              'models': ['claude-opus-4']
            },
          ],
        };
      }
      if (m == 'config.get') return {'value': 'fast'};
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    // Bookmarks start empty; no "Bookmarked" section.
    expect(store.bookmarked, isEmpty);
    expect(find.text('Bookmarked'), findsNothing);

    // Bookmark gpt-4o-mini through the store API (same path the star
    // button uses) and verify the picker reflects it.
    store.toggleBookmark('openai:gpt-4o-mini');
    await tester.pumpAndSettle();

    expect(store.bookmarked, {'openai:gpt-4o-mini'});
    // The pinned "Bookmarked" section is now visible.
    expect(find.text('Bookmarked'), findsOneWidget);

    // Collapse the Anthropic category through the store API.
    store.setProviderCollapsed('anthropic', true);
    await tester.pumpAndSettle();
    expect(store.isProviderCollapsed('anthropic'), isTrue);
    expect(find.text('claude-opus-4'), findsNothing);

    // Uncollapse — the section reappears.
    store.setProviderCollapsed('anthropic', false);
    await tester.pumpAndSettle();
    expect(store.isProviderCollapsed('anthropic'), isFalse);
    expect(find.text('claude-opus-4'), findsOneWidget);
  });

  test('bookmark and collapse state persist to SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({});
    final gw = StoreGateway();
    gw.handler = (m, p) {
      if (m == 'model.options') {
        return {
          'model': 'openai/gpt-4o',
          'provider': 'openai',
          'providers': [
            {
              'slug': 'openai',
              'name': 'OpenAI',
              'is_current': true,
              'authenticated': true,
              'models': ['gpt-4o', 'gpt-4o-mini']
            },
            {
              'slug': 'anthropic',
              'name': 'Anthropic',
              'is_current': false,
              'authenticated': true,
              'models': ['claude-opus-4']
            },
          ],
        };
      }
      return {};
    };
    // First store: set bookmarks + collapse, persist.
    final store = ChatStore(config: config, client: gw);
    await store.loadModels();
    await store.loadPickerState();
    store.toggleBookmark('openai:gpt-4o-mini');
    store.setProviderCollapsed('anthropic', true);
    // Let the fire-and-forget persist complete.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Second store: read back from SharedPreferences.
    final store2 = ChatStore(config: config, client: gw);
    await store2.loadModels();
    await store2.loadPickerState();

    expect(store2.bookmarked, {'openai:gpt-4o-mini'});
    expect(store2.isProviderCollapsed('anthropic'), isTrue);
    expect(store2.bookmarkedModels.length, 1);
    expect(store2.bookmarkedModels.first.slug, 'gpt-4o-mini');
  });

  test('splitModelRef separates provider-prefixed model refs', () {
    expect(ChatStore.splitModelRef('gpt-5'), (slug: 'gpt-5', provider: ''));
    expect(ChatStore.splitModelRef('custom:lab/foo'),
        (slug: 'foo', provider: 'custom:lab'));
    expect(ChatStore.splitModelRef('vendor/model-with-slash'),
        (slug: 'model-with-slash', provider: 'vendor'));
  });

  testWidgets('tapping a provider header actually collapses and expands it',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final gw = StoreGateway();
    gw.handler = (m, p) {
      if (m == 'model.options') {
        return {
          'model': 'openai/gpt-4o',
          'provider': 'openai',
          'providers': [
            {
              'slug': 'openai',
              'name': 'OpenAI',
              'is_current': true,
              'authenticated': true,
              'models': ['gpt-4o']
            },
            {
              'slug': 'anthropic',
              'name': 'Anthropic',
              'is_current': false,
              'authenticated': true,
              'models': ['claude-opus-4']
            },
          ],
        };
      }
      if (m == 'config.get') return {'value': 'fast'};
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: store)));
    await tester.pumpAndSettle();
    expect(find.text('claude-opus-4'), findsOneWidget);

    await tester.tap(find.text('Anthropic'));
    await tester.pumpAndSettle();
    expect(store.isProviderCollapsed('anthropic'), isTrue);
    expect(find.text('claude-opus-4'), findsNothing);

    await tester.tap(find.text('Anthropic'));
    await tester.pumpAndSettle();
    expect(store.isProviderCollapsed('anthropic'), isFalse);
    expect(find.text('claude-opus-4'), findsOneWidget);
  });

  test('sessions.changed rehydrates an active conversation changed elsewhere',
      () async {
    final gw = StoreGateway();
    var historyCalls = 0;
    gw.handler = (m, p) {
      if (m == 'session.history') {
        historyCalls++;
        return {
          'messages': [
            {'role': 'user', 'text': 'from desktop'},
            {'role': 'assistant', 'text': 'synced reply'},
          ]
        };
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    gw.emit('sessions.changed', const {}, sid: '');
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(historyCalls, 1);
    expect(store.messages.map((m) => m.text).toList(),
        ['from desktop', 'synced reply']);
  });

  testWidgets('toolbar exposes new conversation and connection controls',
      (tester) async {
    final gw = StoreGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    await tester
        .pumpWidget(MaterialApp(home: HomeScreen(storeOverride: store)));
    await tester.pumpAndSettle();

    final createsBefore = gw.count('session.create');
    await tester.tap(find.byTooltip('New conversation'));
    await tester.pumpAndSettle();
    expect(gw.count('session.create'), createsBefore + 1);

    await tester.tap(find.text('connected'));
    await tester.pumpAndSettle();
    expect(find.text('Gateway'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Quit Talaria'), findsOneWidget);
  });

  testWidgets('connection sheet updates live when connection state changes',
      (tester) async {
    final gw = StoreGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    await tester
        .pumpWidget(MaterialApp(home: HomeScreen(storeOverride: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('connected'));
    await tester.pumpAndSettle();
    expect(find.text('Disconnect'), findsOneWidget);

    gw.emitState(GwConnectionState.closed);
    await tester.pumpAndSettle();
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
  });

  test('ordinary disconnect closes a reusable client instead of disposing it',
      () async {
    final gw = StoreGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    await store.disconnect();

    expect(gw.closeCalled, isTrue);
    expect(gw.disposeCalled, isFalse,
        reason: 'Disconnect must leave the client reusable for Reconnect');

    final connectsBefore = gw.connectCalls;
    await store.connect();
    expect(gw.connectCalls, connectsBefore + 1);
    expect(store.activeSessionId, 'live-fresh');
  });

  test('cross-client history pulls are serialized and newest refresh wins',
      () async {
    final gw = StoreGateway();
    final first = Completer<Map<String, dynamic>>();
    var historyCalls = 0;
    gw.handler = (m, p) {
      if (m == 'session.history') {
        historyCalls++;
        if (historyCalls == 1) return first.future;
        return {
          'messages': [
            {'role': 'assistant', 'text': 'newest'},
          ]
        };
      }
      return <String, dynamic>{};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    gw.emit('sessions.changed', const {}, sid: '');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(historyCalls, 1);

    // A second signal while the first history RPC is unresolved must queue,
    // not start a competing request that can race the older response.
    gw.emit('sessions.changed', const {}, sid: '');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(historyCalls, 1);

    first.complete({
      'messages': [
        {'role': 'assistant', 'text': 'stale'},
      ]
    });
    await Future<void>.delayed(const Duration(milliseconds: 850));

    expect(historyCalls, 2);
    expect(store.messages.single.text, 'newest');
  });

  test('sessions.changed received while streaming is refreshed after turn end',
      () async {
    final gw = StoreGateway();
    var historyCalls = 0;
    gw.handler = (m, p) {
      if (m == 'session.history') {
        historyCalls++;
        return {
          'messages': [
            {'role': 'user', 'text': 'mobile turn'},
            {'role': 'assistant', 'text': 'external latest'},
          ]
        };
      }
      return <String, dynamic>{};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.connect();
    await store.send('mobile turn');
    expect(store.streaming, isTrue);

    gw.emit('sessions.changed', const {}, sid: '');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(historyCalls, 0,
        reason: 'history must not clobber an actively streaming bubble');

    gw.emit('message.complete', {'text': 'own completion'});
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(historyCalls, 1,
        reason: 'the deferred external-change signal must run after turn end');
    expect(store.messages.last.text, 'external latest');
  });

  test('reconnect refreshes transcript changes committed while socket was down',
      () async {
    final gw = StoreGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    var historyCalls = 0;
    gw.handler = (m, p) {
      if (m == 'session.history') {
        historyCalls++;
        return {
          'messages': [
            {'role': 'assistant', 'text': 'committed while offline'}
          ]
        };
      }
      return {};
    };

    gw.emitState(GwConnectionState.closed);
    await Future<void>.delayed(Duration.zero);
    gw.emitState(GwConnectionState.open);
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(historyCalls, 1);
    expect(store.messages.single.text, 'committed while offline');
  });

  testWidgets('rapid New conversation taps create only one gateway draft',
      (tester) async {
    final gw = StoreGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.connect();

    final create = Completer<Map<String, dynamic>>();
    gw.handler = (m, p) {
      if (m == 'session.create') return create.future;
      return {};
    };
    await tester
        .pumpWidget(MaterialApp(home: HomeScreen(storeOverride: store)));
    await tester.pumpAndSettle();

    final before = gw.count('session.create');
    await tester.tap(find.byTooltip('New conversation'));
    await tester.pump();
    final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.add_comment_outlined));
    expect(button.onPressed, isNull,
        reason: 'the toolbar must lock while session.create is in flight');
    await tester.tap(find.byTooltip('New conversation'), warnIfMissed: false);
    expect(gw.count('session.create'), before + 1);

    create.complete({'session_id': 'live-only-once'});
    await tester.pumpAndSettle();
    expect(store.activeSessionId, 'live-only-once');
    expect(store.creatingSession, isFalse);
  });

  testWidgets('Quit Talaria reaches SystemNavigator.pop after closing sheet',
      (tester) async {
    final platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final gw = StoreGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.connect();
    await tester
        .pumpWidget(MaterialApp(home: HomeScreen(storeOverride: store)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('connected'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quit Talaria'));
    await tester.pumpAndSettle();

    expect(gw.closeCalled, isTrue);
    expect(platformCalls.map((c) => c.method), contains('SystemNavigator.pop'));
  });
}
