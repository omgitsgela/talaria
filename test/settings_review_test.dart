import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/store/chat_store.dart';
import 'package:talaria/src/screens/settings_screen.dart';

final config = GatewayConfig(url: 'http://localhost:1');

/// Fake gateway that records calls and allows per-method responses.
class SettingsGateway extends GatewayClient {
  SettingsGateway() : super(config);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];
  int configSetCount = 0;
  /// Per-method response overrides. If a method is not in [responses] and
  /// [handler] returns null, the built-in defaults (switch) are used.
  Map<String, dynamic> Function(String method, Map<String, dynamic> params)?
      handler;

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
    calls.add((method, params));
    // Per-method override takes priority.
    if (handler != null) {
      final override = handler!(method, params);
      if (override.isNotEmpty) return override;
    }
    // Built-in defaults for data-loading methods.
    return switch (method) {
      'session.list' => {'sessions': []},
      'session.most_recent' => {'session_id': null},
      'session.resume' => {
          'session_id': 'live-${params['session_id']}',
          'resumed': params['session_id'],
          'messages': <Map<String, dynamic>>[],
          'info': {'model': 'openai/gpt-4o'}
        },
      'model.options' => {
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
              'models': [
                {'slug': 'claude-opus-4', 'id': 'claude-opus-4'}
              ]
            }
          ]
        },
      'profiles.list' => {
          'profiles': [
            {'name': 'default', 'is_default': true, 'description': 'Default'}
          ]
        },
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

  // ── setModel returns structured result ──────────────────────────────

  test(
      'setModel returns SetModelResult with confirmRequired when gateway '
      'returns confirm_required', () async {
    final gw = SettingsGateway();
    gw.handler = (m, p) {
      if (m == 'config.set') {
        return {
          'value': 'claude-opus-4',
          'confirm_required': true,
          'confirm_message': 'claude-opus-4 costs \$15/MTok. Confirm?'
        };
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');

    final result = await store.setModel('anthropic/claude-opus-4');
    expect(result.isConfirmRequired, isTrue);
    expect(result.value, 'claude-opus-4');
    expect(result.confirmMessage, contains('costs'));
    // currentModel must NOT update when confirmation required.
    expect(store.currentModel, isNot('claude-opus-4'));
  });

  test('setModel returns SetModelResult with success when model applied',
      () async {
    final gw = SettingsGateway();
    gw.handler = (m, p) {
      if (m == 'config.set') {
        return {'value': 'openai/gpt-4o'};
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');

    final result = await store.setModel('openai/gpt-4o');
    expect(result.isSuccess, isTrue);
    expect(result.value, 'openai/gpt-4o');
    expect(store.currentModel, 'openai/gpt-4o');
  });

  test(
      'setModel with confirmExpensive passes confirm_expensive_model=true '
      'and succeeds on confirmed resend', () async {
    final gw = SettingsGateway();
    gw.handler = (m, p) {
      if (m == 'config.set') {
        // First call (no confirm) returns confirm_required.
        // Second call (with confirm_expensive_model) returns success.
        if (p['confirm_expensive_model'] == true) {
          return {'value': 'anthropic/claude-opus-4'};
        }
        return {
          'value': 'claude-opus-4',
          'confirm_required': true,
          'confirm_message': 'Expensive'
        };
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');

    // First call: triggers confirm
    final first = await store.setModel('anthropic/claude-opus-4');
    expect(first.isConfirmRequired, isTrue);

    // Second call: resend with confirm
    final second =
        await store.setModel('anthropic/claude-opus-4', confirmExpensive: true);
    expect(second.isSuccess, isTrue);
    expect(store.currentModel, 'anthropic/claude-opus-4');

    // Verify the second request had confirm_expensive_model=true
    final configSetCalls =
        gw.calls.where((c) => c.$1 == 'config.set').toList();
    expect(configSetCalls, hasLength(2));
    expect(configSetCalls[1].$2['confirm_expensive_model'], true);
  });

  // ── loadModels: accurate isCurrent ──────────────────────────────────

  test(
      'loadModels marks only the actual current model as isCurrent, '
      'not all models from the current provider', () async {
    final gw = SettingsGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.loadModels();

    // openai provider has is_current=true, but only gpt-4o should be marked
    // current (matches top-level model "openai/gpt-4o").
    final gpt4o = store.models.firstWhere((m) => m.slug == 'gpt-4o');
    final gpt4oMini =
        store.models.firstWhere((m) => m.slug == 'gpt-4o-mini');
    final claude = store.models.firstWhere((m) => m.slug == 'claude-opus-4');

    expect(gpt4o.isCurrent, isTrue,
        reason: 'gpt-4o matches the current model');
    expect(gpt4oMini.isCurrent, isFalse,
        reason: 'gpt-4o-mini is in the current provider but is not the '
            'current model');
    expect(claude.isCurrent, isFalse);
  });

  test(
      'loadModels sets current model from top-level model field, '
      'not provider-level is_current', () async {
    final gw = SettingsGateway();
    gw.handler = (m, p) {
      if (m == 'model.options') {
        return {
          'model': 'anthropic/claude-opus-4',
          'provider': 'anthropic',
          'providers': [
            {
              'slug': 'openai',
              'name': 'OpenAI',
              'is_current': false,
              'authenticated': true,
              'models': ['gpt-4o']
            },
            {
              'slug': 'anthropic',
              'name': 'Anthropic',
              'is_current': true,
              'authenticated': true,
              'models': [
                {'slug': 'claude-opus-4', 'id': 'claude-opus-4'},
                {'slug': 'claude-sonnet-4', 'id': 'claude-sonnet-4'}
              ]
            }
          ]
        };
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.loadModels();

    final opus =
        store.models.firstWhere((m) => m.slug == 'claude-opus-4');
    final sonnet =
        store.models.firstWhere((m) => m.slug == 'claude-sonnet-4');
    final gpt = store.models.firstWhere((m) => m.slug == 'gpt-4o');

    expect(opus.isCurrent, isTrue,
        reason: 'claude-opus-4 is the actual current model');
    expect(sonnet.isCurrent, isFalse,
        reason: 'claude-sonnet-4 shares the provider but is not current');
    expect(gpt.isCurrent, isFalse);
  });

  // ── configGet passes session_id ─────────────────────────────────────

  test('configGet passes session_id for session-scoped keys', () async {
    final gw = SettingsGateway();
    gw.handler = (m, p) {
      if (m == 'config.get') {
        return {'value': 'fast'};
      }
      if (m == 'session.resume') {
        return {
          'session_id': 'live-a',
          'resumed': 'a',
          'messages': <Map<String, dynamic>>[],
        };
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.resumeSession('a');

    await store.configGet('fast');
    final getConfig =
        gw.calls.where((c) => c.$1 == 'config.get').toList();
    expect(getConfig, isNotEmpty);
    expect(getConfig.last.$2['session_id'], 'live-a',
        reason: 'configGet must pass session_id so session-local '
            'keys (fast, reasoning) resolve session-scoped values');
  });

  // ── Toggle values match gateway contract ────────────────────────────

  test('configToggles values match gateway accepted values', () {
    // From gateway methods_config_set.py:
    // fast: FAST_WORDS = {"fast", "on", "normal", "off", "auto", "cold"}
    // reasoning: REASONING_DISPLAY_WORDS + effort levels
    // approval_mode: APPROVAL_MODES = {"manual", "smart", "off"}
    // details_mode: DETAIL_MODES = {"hidden", "collapsed", "expanded"}
    // thinking_mode: THINKING_MODES = {"collapsed", "truncated", "full"}
    // theme: {"auto", "light", "dark"}

    expect(ChatStore.configToggles['approval_mode'],
        unorderedEquals(['manual', 'smart', 'off']),
        reason: 'Gateway _APPROVAL_MODES = {manual, smart, off}');

    expect(ChatStore.configToggles['details_mode'],
        unorderedEquals(['hidden', 'collapsed', 'expanded']),
        reason: 'Gateway _DETAIL_MODES = {hidden, collapsed, expanded}');

    expect(ChatStore.configToggles['thinking_mode'],
        unorderedEquals(['collapsed', 'truncated', 'full']),
        reason: 'Gateway _THINKING_MODES = {collapsed, truncated, full}');

    expect(ChatStore.configToggles['fast'],
        unorderedEquals(['fast', 'normal', 'auto', 'cold']),
        reason: 'Gateway _FAST_WORDS aliases; these are canonical set values');

    expect(ChatStore.configToggles['theme'],
        unorderedEquals(['auto', 'light', 'dark']),
        reason: 'Gateway tui_theme accepts auto|light|dark');

    // reasoning should include display words matching the gateway's
    // _REASONING_DISPLAY_WORDS (show/hide/full/clamp) — 'off' is a
    // setter alias for 'hide', not an effort level.
    expect(ChatStore.configToggles['reasoning'],
        unorderedEquals(['show', 'hide', 'full', 'clamp']),
        reason: 'Gateway _REASONING_DISPLAY_WORDS: '
            '{show,on}→show, {hide,off}→hide, {full,all}→full, {clamp,…}→clamp');
  });

  // ── Widget tests: model confirmation dialog ─────────────────────────

  testWidgets(
      'accepting expensive model confirmation resubmits with '
      'confirm_expensive_model=true', (tester) async {
    final gw = SettingsGateway();
    // Track the number of config.set model calls
    final modelCalls = <Map<String, dynamic>>[];
    gw.handler = (m, p) {
      if (m == 'config.set' && p['key'] == 'model') {
        modelCalls.add(p);
        if (p['confirm_expensive_model'] == true) {
          return {'value': 'anthropic/claude-opus-4'};
        }
        return {
          'value': 'claude-opus-4',
          'confirm_required': true,
          'confirm_message': 'claude-opus-4 costs \$15/MTok'
        };
      }
      if (m == 'config.get') {
        return {'value': 'fast'};
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(store: store),
    ));
    // Wait for _load to complete
    await tester.pumpAndSettle();

    // Find the "Use" button for claude-opus-4
    final useButton = find.widgetWithText(TextButton, 'Use');
    expect(useButton, findsWidgets);

    // Tap the last "Use" button (claude is after the openai models)
    await tester.tap(useButton.last);
    await tester.pumpAndSettle();

    // A confirmation dialog should appear
    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'Confirmation dialog must appear for expensive model');
    expect(find.textContaining('Confirm'), findsWidgets,
        reason: 'Dialog must have a confirm action');

    // Tap the confirm button
    final confirmBtn = find.widgetWithText(TextButton, 'Confirm');
    if (confirmBtn.evaluate().isNotEmpty) {
      await tester.tap(confirmBtn);
    } else {
      // Try with ElevatedButton or other button types
      await tester.tap(find.text('Confirm').last);
    }
    await tester.pumpAndSettle();

    // Verify the model was set with confirm_expensive_model=true
    expect(modelCalls, hasLength(2),
        reason: 'Should send config.set twice: first attempt + confirmed');
    expect(modelCalls[1]['confirm_expensive_model'], true,
        reason: 'Confirmed resend must carry confirm_expensive_model=true');
  });

  testWidgets('canceling expensive model dialog does not resubmit',
      (tester) async {
    final gw = SettingsGateway();
    final modelCalls = <Map<String, dynamic>>[];
    gw.handler = (m, p) {
      if (m == 'config.set' && p['key'] == 'model') {
        modelCalls.add(p);
        return {
          'value': 'claude-opus-4',
          'confirm_required': true,
          'confirm_message': 'Expensive model'
        };
      }
      if (m == 'config.get') {
        return {'value': 'fast'};
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(store: store),
    ));
    await tester.pumpAndSettle();

    // Tap "Use" on claude
    final useButton = find.widgetWithText(TextButton, 'Use');
    await tester.tap(useButton.last);
    await tester.pumpAndSettle();

    // Cancel the dialog
    expect(find.byType(AlertDialog), findsOneWidget);
    final cancelBtn = find.text('Cancel');
    if (cancelBtn.evaluate().isNotEmpty) {
      await tester.tap(cancelBtn);
    } else {
      // Dismiss dialog by tapping outside
      await tester.tapAt(Offset.zero);
    }
    await tester.pumpAndSettle();

    // Only one config.set call (the initial attempt, no confirm resend)
    expect(modelCalls, hasLength(1),
        reason: 'Cancel must not trigger a confirmed resend');
    expect(modelCalls[0]['confirm_expensive_model'], isNot(true));
  });

  // ── Widget test: provider-aware model selection ─────────────────────

  testWidgets('model selection passes provider/slug format to setModel',
      (tester) async {
    final gw = SettingsGateway();
    final modelCalls = <Map<String, dynamic>>[];
    gw.handler = (m, p) {
      if (m == 'config.set' && p['key'] == 'model') {
        modelCalls.add(p);
        return {'value': p['value']};
      }
      if (m == 'config.get') {
        return {'value': 'fast'};
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(store: store),
    ));
    await tester.pumpAndSettle();

    // Tap "Use" on claude-opus-4 (the non-current model from anthropic)
    final useButton = find.widgetWithText(TextButton, 'Use');
    expect(useButton, findsWidgets);
    await tester.tap(useButton.last);
    await tester.pumpAndSettle();

    // Preserve the model token and route the provider with the gateway's
    // explicit flag. Prefixing the model changes slash-containing IDs.
    expect(modelCalls, isNotEmpty);
    expect(modelCalls.last['value'],
        'claude-opus-4 --provider anthropic');
  });

  // ── Widget test: current model accuracy ─────────────────────────────

  testWidgets('only the actual current model shows checkmark',
      (tester) async {
    final gw = SettingsGateway();
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(store: store),
    ));
    await tester.pumpAndSettle();

    // Only gpt-4o should show the green check (it matches "openai/gpt-4o").
    // gpt-4o-mini should show a radio_button_unchecked even though its
    // provider is_current=true.
    expect(find.byIcon(Icons.check_circle), findsOneWidget,
        reason: 'Only one model should be marked current');
  });

  // ── Regression: slash-containing model identifiers ─────────────────

  test(
      'loadModels handles model slugs containing "/" without double-prefixing',
      () async {
    final gw = SettingsGateway();
    gw.handler = (m, p) {
      if (m == 'model.options') {
        return {
          'model': 'custom/ri.language-model-service..language-model.foo',
          'provider': 'custom',
          'providers': [
            {
              'slug': 'custom',
              'name': 'Custom',
              'is_current': true,
              'authenticated': true,
              'models': [
                'ri.language-model-service..language-model.foo',
                'ri.language-model-service..language-model.bar'
              ]
            },
          ]
        };
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.loadModels();

    final foo = store.models
        .firstWhere((m) => m.slug == 'ri.language-model-service..language-model.foo');
    final bar = store.models
        .firstWhere((m) => m.slug == 'ri.language-model-service..language-model.bar');

    expect(foo.isCurrent, isTrue,
        reason: 'Slash-containing slug matches via fullSlug comparison');
    expect(bar.isCurrent, isFalse,
        reason: 'Sibling slash-containing slug must not match');
    expect(foo.provider, 'custom');
  });

  // ── Regression: duplicate model names across providers ──────────────

  test(
      'loadModels does not mark same-named model in another provider '
      'as current', () async {
    final gw = SettingsGateway();
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
              'slug': 'azure',
              'name': 'Azure OpenAI',
              'is_current': false,
              'authenticated': true,
              'models': ['gpt-4o'] // Same model name, different provider
            },
          ]
        };
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);
    await store.loadModels();

    expect(store.models, hasLength(2));
    final openaiGpt = store.models.firstWhere((m) => m.provider == 'openai');
    final azureGpt = store.models.firstWhere((m) => m.provider == 'azure');

    expect(openaiGpt.isCurrent, isTrue,
        reason: 'openai/gpt-4o is the current model');
    expect(azureGpt.isCurrent, isFalse,
        reason: 'azure/gpt-4o is a different provider; must not be marked current');
  });

  // ── configGet reads display field for reasoning ─────────────────────

  test('configGet reads display field when present (reasoning getter)',
      () async {
    final gw = SettingsGateway();
    gw.handler = (m, p) {
      if (m == 'config.get' && p['key'] == 'reasoning') {
        // Gateway returns effort in value, display toggle in display.
        return {'value': 'medium', 'display': 'show'};
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    final v = await store.configGet('reasoning');
    expect(v, 'show',
        reason: 'configGet must read the display field for reasoning');
  });

  test('configGet falls back to value when no display field', () async {
    final gw = SettingsGateway();
    gw.handler = (m, p) {
      if (m == 'config.get' && p['key'] == 'fast') {
        return {'value': 'normal'};
      }
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    final v = await store.configGet('fast');
    expect(v, 'normal',
        reason: 'configGet must fall back to value when no display field');
  });

  // ── Widget: _pickModel guards setState after cancel ─────────────────

  testWidgets('canceling expensive model dialog then navigating away '
      'does not throw', (tester) async {
    final gw = SettingsGateway();
    gw.handler = (m, p) {
      if (m == 'config.set' && p['key'] == 'model') {
        return {
          'value': 'claude-opus-4',
          'confirm_required': true,
          'confirm_message': 'Expensive'
        };
      }
      if (m == 'config.get') return {'value': 'fast'};
      return {};
    };
    final store = ChatStore(config: config, client: gw);
    addTearDown(store.dispose);

    await tester.pumpWidget(MaterialApp(
      home: SettingsScreen(store: store),
    ));
    await tester.pumpAndSettle();

    // Tap "Use" on claude to trigger confirm dialog
    final useButton = find.widgetWithText(TextButton, 'Use');
    await tester.tap(useButton.last);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    // Cancel the dialog
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // The widget is still mounted and the snackbar does not throw.
    // This exercises the mounted guard after the awaited dialog.
    expect(find.byType(SettingsScreen), findsOneWidget);
  });
}
