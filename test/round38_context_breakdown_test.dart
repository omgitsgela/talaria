import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/models/context_breakdown.dart';
import 'package:talaria/src/models/context_usage.dart';
import 'package:talaria/src/widgets/context_meter.dart';

/// Context breakdown model + meter (Round 38, issue #13).
///
/// Payload shapes are taken from the gateway source:
/// `tui_gateway/methods_session.py` (`session.context_breakdown`) and
/// `agent/context_breakdown.py` (`compute_session_context_breakdown`), which
/// emits only categories with tokens > 0, a top-level
/// `context_used`/`context_max`/`context_percent` triple identical in shape
/// to the usage payload, plus `estimated_total`, `context_source`,
/// `context_estimated` and `model`. A session with no live agent gets the
/// zeroed fallback shape instead.

/// The real reply shape for a live session (gateway omits zero-token
/// categories, so `subagent_definitions` at 0 is absent here).
Map<String, dynamic> _fullPayload() => {
      'categories': [
        {'color': 'var(--context-usage-system)', 'id': 'system_prompt', 'label': 'System prompt', 'tokens': 4200},
        {'color': 'var(--context-usage-tools)', 'id': 'tool_definitions', 'label': 'Tool definitions', 'tokens': 3100},
        {'color': 'var(--context-usage-rules)', 'id': 'rules', 'label': 'Rules', 'tokens': 800},
        {'color': 'var(--context-usage-skills)', 'id': 'skills', 'label': 'Skills', 'tokens': 1500},
        {'color': 'var(--context-usage-mcp)', 'id': 'mcp', 'label': 'MCP', 'tokens': 600},
        {'color': 'var(--context-usage-memory)', 'id': 'memory', 'label': 'Memory', 'tokens': 900},
        {'color': 'var(--context-usage-conversation)', 'id': 'conversation', 'label': 'Conversation', 'tokens': 7100},
      ],
      'context_max': 128000,
      'context_percent': 19,
      'context_used': 24500,
      'context_source': 'provider_usage',
      'context_estimated': false,
      'estimated_total': 18200,
      'model': 'test-model',
    };

/// The real reply shape when the session has no live agent
/// (`methods_session.py` zeroed fallback).
Map<String, dynamic> _noAgentPayload() => {
      'categories': const <Map<String, dynamic>>[],
      'context_max': 0,
      'context_percent': 0,
      'context_used': 0,
      'estimated_total': 0,
      'context_estimated': false,
      'context_source': 'provider_usage',
      'model': '',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ContextBreakdown parsing (round 38)', () {
    test('reads a full real-shaped reply', () {
      final b = ContextBreakdown.fromPayload(_fullPayload());
      expect(b.hasData, isTrue);
      expect(b.categories.length, 7);
      expect(b.categories.first.id, 'system_prompt');
      expect(b.categories.first.label, 'System prompt');
      expect(b.categories.first.tokens, 4200);
      expect(b.categories.last.label, 'Conversation');

      expect(b.used, 24500);
      expect(b.window, 128000);
      expect(b.percent, 19);
      expect(b.remaining, 128000 - 24500);
      expect(b.estimatedTotal, 18200);
      expect(b.model, 'test-model');
      expect(b.source, 'provider_usage');
      expect(b.estimated, isFalse);
    });

    test('category shares are fractions of the total and of the window', () {
      final b = ContextBreakdown.fromPayload(_fullPayload());
      final shareSum =
          b.categories.fold<double>(0, (s, c) => s + c.shareOfTotal);
      expect(shareSum, closeTo(1.0, 1e-9));
      final conversation = b.categories.last;
      expect(conversation.shareOfTotal, closeTo(7100 / 18200, 1e-9));
      expect(conversation.shareOfWindow, closeTo(7100 / 128000, 1e-9));
    });

    test('the occupancy and the breakdown come from one parsing path', () {
      final payload = _fullPayload();
      final b = ContextBreakdown.fromPayload(payload);
      // ContextUsage.fromBreakdown is fromUsage under another name, and the
      // breakdown's own usage view delegates to the same code: no drift.
      expect(ContextUsage.fromBreakdown(payload), b.usage);
      expect(b.usage.used, 24500);
      expect(b.usage.max, 128000);
      expect(b.usage.percent, 19);
      expect(b.usage.label, '24.5k/128k');
    });

    test('missing optional sections degrade instead of throwing', () {
      // Only categories: no window, no counts, no model.
      final partial = ContextBreakdown.fromPayload({
        'categories': [
          {'id': 'conversation', 'label': 'Conversation', 'tokens': 500},
        ],
      });
      expect(partial.hasData, isTrue);
      expect(partial.window, isNull);
      expect(partial.used, isNull);
      expect(partial.percent, isNull);
      expect(partial.remaining, isNull);
      expect(partial.model, isNull);
      expect(partial.source, isNull);
      expect(partial.categories.single.shareOfWindow, isNull,
          reason: 'no window: a window share would be invented');
      expect(partial.categories.single.shareOfTotal, 1.0);

      // Nothing at all.
      expect(ContextBreakdown.fromPayload(null).hasData, isFalse);
      expect(ContextBreakdown.fromPayload(const {}).hasData, isFalse);
    });

    test('tolerates malformed entries and JSON-shaped strings', () {
      final b = ContextBreakdown.fromPayload({
        'categories': [
          'not a map',
          {'id': 'skills', 'tokens': '1500'},
          {'label': 'No id, negative', 'tokens': -20},
          {'id': 'memory', 'label': 'Memory', 'tokens': 900.0},
        ],
        'context_used': '2400',
        'context_max': '128000',
        'context_percent': 900,
      });
      expect(b.categories.length, 3);
      expect(b.categories[0].tokens, 1500);
      expect(b.categories[0].label, 'skills',
          reason: 'an unlabeled category falls back to its id');
      expect(b.categories[1].tokens, 0,
          reason: 'a negative count clamps to 0, never underflows a share');
      expect(b.categories[1].shareOfTotal, 0);
      expect(b.used, 2400);
      expect(b.window, 128000);
      expect(b.percent, 100, reason: 'a bogus percent clamps, not prints raw');
    });

    test('the no-agent zeroed fallback has nothing to show', () {
      final b = ContextBreakdown.fromPayload(_noAgentPayload());
      expect(b.hasData, isFalse);
      expect(b.categories, isEmpty);
      expect(b.model, isNull);
    });

    test('zero usage against a known window still counts as data', () {
      final b = ContextBreakdown.fromPayload({
        'categories': const <Map<String, dynamic>>[],
        'context_max': 128000,
        'context_used': 0,
        'context_percent': 0,
      });
      expect(b.hasData, isTrue, reason: 'the window itself is a fact');
      expect(b.remaining, 128000);
      expect(b.usage.isKnown, isFalse,
          reason: 'the usage contract keeps a zero reading unknown');
    });
  });

  group('ContextMeter widget (round 38)', () {
    Future<void> pumpMeter(WidgetTester tester, ContextBreakdown b) async {
      // 400x800 logical pixels, a phone-sized window.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: ContextMeter(breakdown: b),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('renders the window headline and expands the categories',
        (tester) async {
      await pumpMeter(tester, ContextBreakdown.fromPayload(_fullPayload()));

      expect(find.text('24.5k of 128k (19%)'), findsOneWidget);
      expect(find.text('System prompt'), findsNothing,
          reason: 'the detail list stays collapsed until asked');
      expect(tester.takeException(), isNull);

      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pump();

      expect(find.text('System prompt'), findsOneWidget);
      expect(find.text('Tool definitions'), findsOneWidget);
      expect(find.text('Conversation'), findsOneWidget);
      expect(find.text('7.1k (39%)'), findsOneWidget,
          reason: 'each row shows its tokens and its share of the total');
      expect(find.text('Estimated locally, not measured by the provider.'),
          findsNothing,
          reason: 'a provider-measured reading is not flagged as estimated');
      expect(tester.takeException(), isNull,
          reason: 'no overflow at 400x800 logical pixels');
    });

    testWidgets('flags an estimated reading', (tester) async {
      final payload = _fullPayload()
        ..['context_source'] = 'local_estimate'
        ..['context_estimated'] = true;
      await pumpMeter(tester, ContextBreakdown.fromPayload(payload));

      expect(find.text('~24.5k of 128k (19%)'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pump();
      expect(find.text('Estimated locally, not measured by the provider.'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a zero-usage window renders an empty bar, not nothing',
        (tester) async {
      await pumpMeter(
          tester,
          ContextBreakdown.fromPayload({
            'categories': const <Map<String, dynamic>>[],
            'context_max': 128000,
            'context_used': 0,
            'context_percent': 0,
          }));

      expect(find.text('0 of 128k (0%)'), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: 'the empty bar must lay out cleanly at phone size');
    });

    testWidgets('renders nothing when there is nothing truthful to show',
        (tester) async {
      await pumpMeter(tester, ContextBreakdown.fromPayload(_noAgentPayload()));
      expect(find.byType(InkWell), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('window-unknown breakdown fills the bar by category shares',
        (tester) async {
      await pumpMeter(
          tester,
          ContextBreakdown.fromPayload({
            'categories': [
              {'id': 'system_prompt', 'label': 'System prompt', 'tokens': 300},
              {'id': 'conversation', 'label': 'Conversation', 'tokens': 900},
            ],
            'context_used': 1200,
          }));

      expect(find.text('1.2k'), findsOneWidget,
          reason: 'no window: the headline shows only what is known');
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pump();
      expect(find.text('300 (25%)'), findsOneWidget);
      expect(find.text('900 (75%)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
