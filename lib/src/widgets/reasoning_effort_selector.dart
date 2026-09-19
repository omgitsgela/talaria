import 'package:flutter/material.dart';

import '../models/reasoning_effort.dart';

/// Compact reasoning-effort selector for a phone: the live value, one chip
/// per level the gateway accepts, and a plain-language caption spelling out
/// the cost/latency tradeoff.
///
/// The widget is deliberately dumb about its surroundings: it renders the
/// [effort] it is given and reports taps through [onSelect]. Loading,
/// writing, re-reading and error reporting belong to the caller.
class ReasoningEffortSelector extends StatelessWidget {
  const ReasoningEffortSelector({
    super.key,
    required this.effort,
    this.busy = false,
    this.onSelect,
  });

  /// The setting as last read from the gateway.
  final ReasoningEffort effort;

  /// True while a write is in flight; chips are disabled so a second tap
  /// cannot race the re-read.
  final bool busy;

  /// Called with the normalized level when the user picks one. Null disables
  /// the control entirely (offline, or a parent that cannot write).
  final ValueChanged<String>? onSelect;

  /// Plain-language tradeoff per level. Lower effort answers faster and
  /// costs less; higher effort thinks longer and costs more.
  static const descriptions = <String, String>{
    'none': 'Thinking off. Fastest and cheapest.',
    'minimal': 'Barely any thinking. Very fast, very cheap.',
    'low': 'Light thinking. Fast and cheap.',
    'medium': 'Balanced thinking. The default when unset.',
    'high': 'Deeper thinking. Slower and costs more.',
    'xhigh': 'Much deeper thinking. Noticeably slower and pricier.',
    'max': 'Near-maximum thinking. Slow and expensive.',
    'ultra': 'Maximum thinking. Slowest and most expensive.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final current = effort.current;
    final recognized = effort.isRecognized;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Current: ',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant)),
            Text(
              current.isEmpty ? 'unknown' : current,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: recognized ? null : cs.error,
              ),
            ),
          ],
        ),
        if (!recognized && current.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'The gateway reports a value this app does not recognize. '
              'Pick a level below to replace it.',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final level in ReasoningEffort.levels)
              ChoiceChip(
                label: Text(level, style: theme.textTheme.bodySmall),
                selected: level == current,
                onSelected:
                    (busy || onSelect == null || level == current)
                        ? null
                        : (_) => onSelect!(level),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          recognized
              ? descriptions[current]!
              : 'Lower effort is faster and cheaper; higher effort is '
                  'slower and more thorough.',
          style:
              theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}
