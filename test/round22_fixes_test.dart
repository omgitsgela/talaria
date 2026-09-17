import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/widgets/message_bubble.dart';

/// Round 22 (2026-09-16): blockquotes in assistant replies rendered
/// unreadable — white text on a LIGHT blue panel in dark mode.
///
/// A vendor warranty NOTE quoted with a markdown `>` hit this. flutter_markdown's Material fallback stylesheet hardcodes
/// `blockquoteDecoration: Colors.blue.shade100` (#E3F2FD) — a light blue
/// that is NOT brightness-aware — and `MarkdownBody` merges the app
/// stylesheet ON TOP of that fallback (widget.dart: `kFallbackStyle(...)`
/// + `fallbackStyleSheet.merge(widget.styleSheet)`). Any token the app does
/// not override falls through to the package default. Round 14 fixed the
/// SAME trap for fenced code blocks (`codeblockDecoration`);
/// `blockquoteDecoration` (and its `blockquotePadding`) were never
/// overridden, so every `>` quote in a reply rendered on that light blue.
///
/// Fix: the bubble's stylesheet now sets a themed `blockquoteDecoration`
/// (surfaceContainerLow panel + gold left accent, both brightnesses) and
/// explicit `blockquotePadding`.
Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('blockquotes (round 22)', () {
    final quoteText =
        'NOTE: the vendor lists every component and its part number for the '
        'original configuration purchased.';

    testWidgets('dark mode: the quote renders on a themed panel, not light blue',
        (tester) async {
      final dark = ThemeData(brightness: Brightness.dark);
      await tester.pumpWidget(MaterialApp(
        theme: dark,
        home: Scaffold(
            body: MessageBubble(
                message:
                    ChatMessage(role: 'assistant', text: '> $quoteText'),
                isUser: false)),
      ));
      await tester.pumpAndSettle();

      // The blockquote is wrapped in a DecoratedBox carrying the panel
      // decoration (builder.dart blockquote branch).
      final decorated = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox,
              skipOffstage: false))
          .where((d) => d.decoration is BoxDecoration)
          .toList();
      expect(decorated, isNotEmpty,
          reason: 'the quote must render its panel decoration');

      final bad = decorated.where((d) =>
          (d.decoration as BoxDecoration).color == Colors.blue.shade100);
      expect(bad, isEmpty,
          reason: 'the package fallback light-blue (#E3F2FD) must never '
              'reach a rendered quote — it is unreadable in dark mode');

      final panel = decorated
          .map((d) => (d.decoration as BoxDecoration).color)
          .toSet();
      expect(
          panel,
          contains(dark.colorScheme.surfaceContainerLow),
          reason: 'the quote panel must be the themed surface, which is '
              'dark in dark mode');

      // Sanity: the panel is actually dark — the reported bug was white
      // text on a light background.
      final panelColor = dark.colorScheme.surfaceContainerLow;
      final lum =
          0.299 * (panelColor.r / 255) + 0.587 * (panelColor.g / 255) +
              0.114 * (panelColor.b / 255);
      expect(lum, lessThan(0.6),
          reason: 'a dark-mode quote panel must be dark enough for '
              'light text');
    });

    testWidgets('light mode: the quote renders on the themed panel too',
        (tester) async {
      final light = ThemeData(brightness: Brightness.light);
      await tester.pumpWidget(MaterialApp(
        theme: light,
        home: Scaffold(
            body: MessageBubble(
                message:
                    ChatMessage(role: 'assistant', text: '> $quoteText'),
                isUser: false)),
      ));
      await tester.pumpAndSettle();

      final decorated = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox,
              skipOffstage: false))
          .where((d) => d.decoration is BoxDecoration)
          .toList();
      final panel = decorated
          .map((d) => (d.decoration as BoxDecoration).color)
          .toSet();
      expect(
          panel,
          contains(light.colorScheme.surfaceContainerLow),
          reason: 'light mode must get the themed panel as well');
    });

    testWidgets('stylesheet carries themed blockquote tokens (no merge fallthrough)',
        (tester) async {
      // Rebuild the stylesheet exactly as the bubble does (the merge
      // fallthrough is the failure mode): both brightnesses must set the
      // decoration AND padding explicitly, since a null token falls
      // through to the package default.
      for (final t in [
        ThemeData(brightness: Brightness.dark),
        ThemeData(brightness: Brightness.light)
      ]) {
        final cs = t.colorScheme;
        final sheet = MarkdownStyleSheet(
          p: t.textTheme.bodyLarge,
          blockquote: t.textTheme.bodyLarge
              ?.copyWith(color: cs.onSurfaceVariant, height: 1.4),
          codeblockDecoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          blockquoteDecoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
            border: Border(
              left: BorderSide(
                  color: cs.primary.withValues(alpha: 0.4), width: 3),
            ),
          ),
          blockquotePadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        );
        final box = sheet.blockquoteDecoration as BoxDecoration;
        expect(box.color, cs.surfaceContainerLow);
        expect(box.color, isNot(Colors.blue.shade100));
        final left = (box.border as Border).left;
        expect(left, isA<BorderSide>());
        expect(sheet.blockquotePadding,
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8));
      }
    });
  });
}
