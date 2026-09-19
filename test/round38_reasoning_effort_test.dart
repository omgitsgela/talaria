import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/models/reasoning_effort.dart';
import 'package:talaria/src/screens/settings_screen.dart';
import 'package:talaria/src/store/chat_store.dart';
import 'package:talaria/src/widgets/reasoning_effort_selector.dart';

/// Recording fake for the model's injected transport.
class FakeTransport {
  final calls = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic> Function(String method, Map<String, dynamic> params)?
      handler;

  Future<Map<String, dynamic>> call(
      String method, Map<String, dynamic> params) async {
    calls.add((method, params));
    return handler?.call(method, params) ?? <String, dynamic>{};
  }

  Iterable<Map<String, dynamic>> paramsFor(String method) =>
      calls.where((c) => c.$1 == method).map((c) => c.$2);
}

final config = GatewayConfig(url: 'http://localhost:1');

/// Minimal store fake: enough for SettingsScreen._load.
class _ScreenGateway extends GatewayClient {
  _ScreenGateway() : super(config);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);

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
      [Map<String, dynamic> params = const {},
      int timeoutMs = 120000]) async {
    return switch (method) {
      'session.list' => {'sessions': []},
      'session.most_recent' => {'session_id': null},
      'model.options' => {
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
          ]
        },
      'profiles.list' => {'profiles': []},
      'system.battery' => {'level': 0.8, 'charging': false},
      'verification.status' => {
          'verification': {'status': 'verified'}
        },
      'subscription.preview' => {'ok': true, 'plan': 'pro'},
      'session.active_list' => {'sessions': <Map<String, dynamic>>[]},
      _ => {},
    };
  }

  @override
  Future<void> dispose() async {
    await pushed.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReasoningEffort model', () {
    test('load reads the live value from config.get, no assumed default',
        () async {
      final t = FakeTransport();
      t.handler = (m, p) =>
          m == 'config.get' ? {'value': 'xhigh', 'display': 'show'} : {};
      final effort = await ReasoningEffort.load(t.call);
      expect(effort.current, 'xhigh');
      expect(effort.isRecognized, isTrue);
      expect(t.paramsFor('config.get').single['key'], 'reasoning');
    });

    test('load does not invent a value when the gateway returns none',
        () async {
      final t = FakeTransport();
      t.handler = (m, p) => {};
      final effort = await ReasoningEffort.load(t.call);
      expect(effort.current, '');
      expect(effort.isRecognized, isFalse);
    });

    test('write issues config.set reasoning with global scope, then re-reads',
        () async {
      final t = FakeTransport();
      var stored = 'medium';
      t.handler = (m, p) {
        if (m == 'config.set') {
          stored = p['value'] as String;
          return {'key': 'reasoning', 'value': stored};
        }
        if (m == 'config.get') {
          return {'value': stored, 'display': 'show'};
        }
        return {};
      };
      final effort = await ReasoningEffort.load(t.call);
      expect(effort.current, 'medium');
      final res = await effort.write(t.call, 'low');
      expect(res.applied, isTrue);
      expect(res.actual, 'low');

      final setParams = t.paramsFor('config.set').single;
      expect(setParams['key'], 'reasoning');
      expect(setParams['value'], 'low');
      expect(setParams['scope'], 'global',
          reason: 'global scope persists agent.reasoning_effort in '
              'config.yaml (methods_config_set.py:310-311)');
      // The set must be followed by a re-read of the same key.
      final setIndex =
          t.calls.indexWhere((c) => c.$1 == 'config.set');
      final reRead = t.calls
          .sublist(setIndex + 1)
          .where((c) => c.$1 == 'config.get' && c.$2['key'] == 'reasoning');
      expect(reRead, isNotEmpty,
          reason: 'the model must re-read after writing');
    });

    test('write normalizes case and whitespace like the gateway', () async {
      final t = FakeTransport();
      t.handler = (m, p) => m == 'config.get'
          ? {'value': 'high', 'display': 'show'}
          : {'key': 'reasoning', 'value': 'high'};
      final res =
          await const ReasoningEffort('medium').write(t.call, '  HIGH ');
      expect(res.applied, isTrue);
      expect(t.paramsFor('config.set').single['value'], 'high');
    });

    test('a write that does not take effect is a failure, not a success',
        () async {
      final t = FakeTransport();
      // Gateway accepts the set but the re-read keeps the old value.
      t.handler = (m, p) =>
          m == 'config.get' ? {'value': 'medium', 'display': 'show'} : {};
      final res = await const ReasoningEffort('medium').write(t.call, 'ultra');
      expect(res.applied, isFalse);
      expect(res.actual, 'medium');
      expect(res.refused, isFalse);
    });

    test('an unsupported value is refused before any RPC', () async {
      final t = FakeTransport();
      final res =
          await const ReasoningEffort('medium').write(t.call, 'ludicrous');
      expect(res.refused, isTrue);
      expect(res.applied, isFalse);
      expect(t.calls, isEmpty,
          reason: 'a refused value must never reach the gateway');
      expect(ReasoningEffort.isSupported('ludicrous'), isFalse);
      expect(ReasoningEffort.isSupported('none'), isTrue);
      expect(ReasoningEffort.isSupported('ultra'), isTrue);
    });

    test('the accepted set matches the gateway exactly', () {
      // hermes_constants.py:960 VALID_REASONING_EFFORTS plus the disabled
      // word 'none' (hermes_constants.py:972).
      expect(ReasoningEffort.levels, [
        'none',
        'minimal',
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
        'ultra',
      ]);
    });
  });

  group('ReasoningEffortSelector widget', () {
    testWidgets('shows the live value selected, with the tradeoff caption',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ReasoningEffortSelector(effort: ReasoningEffort('high')),
        ),
      ));
      await tester.pump();
      expect(find.text('Current: '), findsOneWidget);
      // 'high' appears as the live value and as its chip label.
      expect(find.text('high'), findsNWidgets(2));
      final chip = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, 'high'));
      expect(chip.selected, isTrue);
      expect(find.textContaining('Deeper thinking'), findsOneWidget);
      // Every gateway level is offered.
      for (final level in ReasoningEffort.levels) {
        expect(find.widgetWithText(ChoiceChip, level), findsOneWidget);
      }
    });

    testWidgets('tapping a level reports it through onSelect', (tester) async {
      String? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ReasoningEffortSelector(
            effort: const ReasoningEffort('medium'),
            onSelect: (level) => picked = level,
          ),
        ),
      ));
      await tester.pump();
      await tester.tap(find.widgetWithText(ChoiceChip, 'low'));
      expect(picked, 'low');
    });

    testWidgets('an unrecognized live value selects nothing and warns',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ReasoningEffortSelector(effort: ReasoningEffort('turbo')),
        ),
      ));
      await tester.pump();
      expect(find.text('turbo'), findsOneWidget);
      expect(find.textContaining('does not recognize'), findsOneWidget);
      for (final level in ReasoningEffort.levels) {
        final chip = tester.widget<ChoiceChip>(
            find.widgetWithText(ChoiceChip, level));
        expect(chip.selected, isFalse,
            reason: 'an unknown value must not be coerced onto a chip');
      }
    });
  });

  group('Settings screen wiring', () {
    Future<ChatStore> pumpSettings(
      WidgetTester tester,
      FakeTransport transport,
    ) async {
      final gw = _ScreenGateway();
      final store = ChatStore(config: config, client: gw);
      addTearDown(store.dispose);
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(store: store, configTransport: transport.call),
      ));
      // Fixed pumps: the card shows a spinner while loading, which would
      // hang pumpAndSettle.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      return store;
    }

    testWidgets('reasoning section shows the live value and writes globally',
        (tester) async {
      final t = FakeTransport();
      var stored = 'high';
      t.handler = (m, p) {
        if (m == 'config.set') {
          stored = p['value'] as String;
          return {'key': 'reasoning', 'value': stored};
        }
        if (m == 'config.get') {
          return {'value': stored, 'display': 'show'};
        }
        return {};
      };
      await pumpSettings(tester, t);

      final section = find.text('Reasoning');
      await tester.dragUntilVisible(
          section, find.byType(ListView), const Offset(0, -200));
      expect(section, findsOneWidget,
          reason: 'the feature must be reachable in Settings');

      final target = find.widgetWithText(ChoiceChip, 'ultra');
      await tester.ensureVisible(target);
      await tester.pump();
      // The live value read from config is what is selected.
      final liveChip = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, 'high'));
      expect(liveChip.selected, isTrue);

      await tester.tap(target);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final setParams = t.paramsFor('config.set').single;
      expect(setParams['key'], 'reasoning');
      expect(setParams['value'], 'ultra');
      expect(setParams['scope'], 'global');
      expect(find.text('reasoning = ultra'), findsOneWidget,
          reason: 'an applied write confirms with the re-read value');
    });

    testWidgets('a write that does not stick is surfaced as a failure',
        (tester) async {
      final t = FakeTransport();
      // The gateway answers the set but the re-read never moves.
      t.handler = (m, p) =>
          m == 'config.get' ? {'value': 'medium', 'display': 'show'} : {};
      await pumpSettings(tester, t);

      await tester.dragUntilVisible(find.text('Reasoning'),
          find.byType(ListView), const Offset(0, -200));
      final target = find.widgetWithText(ChoiceChip, 'ultra');
      await tester.ensureVisible(target);
      await tester.pump();
      await tester.tap(target);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.textContaining('Gateway kept reasoning at'), findsOneWidget,
          reason: 'a silently ignored write must not show as success');
      final chip = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, 'medium'));
      expect(chip.selected, isTrue,
          reason: 'the selector shows what is actually in force');
    });
  });
}
