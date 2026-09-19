import 'package:flutter/material.dart';

import '../models/context_breakdown.dart';
import '../models/context_usage.dart';

/// Compact phone rendering of a [ContextBreakdown]: a stacked bar of the
/// attributed categories against the model's window, a used-against-window
/// label, and an expandable per-category detail list.
///
/// Self-contained on purpose: it takes the parsed view model and nothing
/// else, so it can be dropped into any status area without the transcript
/// screen or the store. A breakdown with nothing truthful to report renders
/// NOTHING, matching the app-bar readout's never-fake-0% rule.
class ContextMeter extends StatefulWidget {
  const ContextMeter({super.key, required this.breakdown});

  final ContextBreakdown breakdown;

  @override
  State<ContextMeter> createState() => _ContextMeterState();
}

class _ContextMeterState extends State<ContextMeter> {
  bool _expanded = false;

  /// Category colors. The gateway sends CSS variables meant for the desktop
  /// dashboard, so the phone derives a stable palette from the theme instead:
  /// the same category always lands on the same color because assignment is
  /// by list position.
  static List<Color> _palette(ColorScheme cs) => [
        cs.primary,
        cs.tertiary,
        cs.secondary,
        cs.error,
        cs.primary.withValues(alpha: 0.55),
        cs.tertiary.withValues(alpha: 0.55),
        cs.secondary.withValues(alpha: 0.55),
        cs.error.withValues(alpha: 0.55),
      ];

  @override
  Widget build(BuildContext context) {
    final breakdown = widget.breakdown;
    if (!breakdown.hasData) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _headline(breakdown),
                    style: muted,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        _UsageBar(breakdown: breakdown, palette: _palette(theme.colorScheme)),
        if (_expanded) ...[
          const SizedBox(height: 6),
          for (var i = 0; i < breakdown.categories.length; i++)
            _CategoryRow(
              category: breakdown.categories[i],
              color: _palette(theme.colorScheme)[
                  i % _palette(theme.colorScheme).length],
              style: muted,
            ),
          if (breakdown.estimated)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Estimated locally, not measured by the provider.',
                style: muted?.copyWith(fontSize: 10),
              ),
            ),
        ],
      ],
    );
  }

  /// `24.5k of 128k (19%)`, degrading to whatever the gateway actually sent.
  static String _headline(ContextBreakdown b) {
    final used = b.used ?? 0;
    final w = b.window;
    final pct = b.percent;
    final of = (w != null && w > 0) ? ' of ${formatTokenCount(w)}' : '';
    final pc = pct != null ? ' ($pct%)' : '';
    final est = b.estimated ? '~' : '';
    return '$est${formatTokenCount(used)}$of$pc';
  }
}

/// The stacked bar. Category segments share the USED portion of the window
/// (their estimates are rescaled to it, since the gateway's measured `used`
/// and its heuristic category sum legitimately differ); whatever is left of
/// the window renders as free track. Without a known window the categories
/// fill the whole bar by their relative shares.
class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.breakdown, required this.palette});

  final ContextBreakdown breakdown;
  final List<Color> palette;

  @override
  Widget build(BuildContext context) {
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
    final segments = <Widget>[];
    final cats = breakdown.categories;
    final window = breakdown.window;
    final used = breakdown.used ?? 0;

    if (cats.isNotEmpty) {
      // Scale category estimates onto the bar: against the real used count
      // when both are known, else against their own sum.
      final base = (used > 0) ? used : cats.fold<int>(0, (s, c) => s + c.tokens);
      for (var i = 0; i < cats.length; i++) {
        final flex = base > 0 ? (cats[i].tokens * 1000) ~/ base : 0;
        if (flex <= 0) continue;
        segments.add(Expanded(
          flex: flex,
          child: ColoredBox(color: palette[i % palette.length]),
        ));
      }
    }

    final usedFlex = () {
      if (window != null && window > 0) {
        return ((used.clamp(0, window)) * 1000) ~/ window;
      }
      return segments.isEmpty ? 0 : 1000;
    }();

    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: Row(
          children: [
            if (usedFlex > 0)
              Expanded(
                flex: usedFlex,
                child: Row(children: segments),
              ),
            if (usedFlex < 1000)
              Expanded(flex: 1000 - usedFlex, child: ColoredBox(color: track)),
          ],
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow(
      {required this.category, required this.color, required this.style});

  final ContextCategory category;
  final Color color;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final share = (category.shareOfTotal * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(category.label, style: style, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Text('${formatTokenCount(category.tokens)} ($share%)', style: style),
        ],
      ),
    );
  }
}
