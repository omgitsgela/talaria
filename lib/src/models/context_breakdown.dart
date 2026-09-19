import 'context_usage.dart';

/// One labelled slice of the context window (system prompt, tools,
/// conversation, ...), as reported by `session.context_breakdown`.
///
/// The gateway (`agent/context_breakdown.py`) emits `id`, `label`, `tokens`
/// and a CSS `color` per category; the color is a web variable and useless on
/// a phone, so it is deliberately not carried here. Every field may be
/// missing in a degraded reply, so parsing never throws.
class ContextCategory {
  const ContextCategory({
    required this.id,
    required this.label,
    required this.tokens,
    required this.shareOfTotal,
    this.shareOfWindow,
  });

  /// Stable gateway id (`system_prompt`, `tool_definitions`, ...), '' when
  /// the entry omitted it.
  final String id;

  /// Human label from the gateway; falls back to the id when unlabeled.
  final String label;

  /// Estimated tokens this category occupies. Never negative.
  final int tokens;

  /// Fraction of the summed category tokens (0..1). 0 when nothing was
  /// attributed at all.
  final double shareOfTotal;

  /// Fraction of the whole model window (0..1), or null when the window
  /// size is unknown.
  final double? shareOfWindow;

  static int _tokensOf(Object? v) {
    int? n;
    if (v is int) {
      n = v;
    } else if (v is num) {
      n = v.toInt();
    } else if (v is String) {
      n = int.tryParse(v.trim());
    }
    if (n == null || n < 0) return 0;
    return n;
  }
}

/// Typed view of the `session.context_breakdown` reply
/// (`tui_gateway/methods_session.py`, built by
/// `agent/context_breakdown.py#compute_session_context_breakdown`).
///
/// Shape: `categories` (only categories with tokens > 0), `context_max` (the
/// model's window, resolved gateway-side from the `model.context_length`
/// config override or model metadata), `context_used`, `context_percent`,
/// `estimated_total`, `context_source`, `context_estimated` and `model`. A
/// session without a live agent answers with empty categories and zeroed
/// counts instead, which is why every field here is optional.
class ContextBreakdown {
  const ContextBreakdown({
    this.categories = const [],
    this.used,
    this.window,
    this.percent,
    this.estimatedTotal,
    this.model,
    this.source,
    this.estimated = false,
  });

  /// Attributed slices, in the gateway's display order.
  final List<ContextCategory> categories;

  /// Tokens currently occupying the window (`context_used`).
  final int? used;

  /// The model's context window (`context_max`).
  final int? window;

  /// Gateway-computed fill percent (`context_percent`).
  final int? percent;

  /// Sum of the category estimates (`estimated_total`). Can differ from
  /// [used]: usage is provider-measured, categories are heuristic estimates.
  final int? estimatedTotal;

  /// Model name the breakdown was computed for.
  final String? model;

  /// Provenance of [used] (`provider_usage`, `local_estimate`, ...).
  final String? source;

  /// True when [used] is an estimate rather than a provider reading.
  final bool estimated;

  static const ContextBreakdown empty = ContextBreakdown();

  /// Anything truthful to show: a known window, a positive reading, or at
  /// least one attributed category.
  bool get hasData =>
      (window != null && window! > 0) ||
      (used != null && used! > 0) ||
      categories.isNotEmpty;

  /// Tokens still free in the window, clamped at 0. Null when either side
  /// is unknown.
  int? get remaining {
    final w = window;
    if (w == null || w <= 0) return null;
    return (w - (used ?? 0)).clamp(0, w);
  }

  /// The same occupancy as a [ContextUsage], parsed through the ONE usage
  /// code path so the app-bar percentage and this breakdown can never
  /// disagree about how the numbers are read.
  ContextUsage get usage => ContextUsage.fromUsage({
        'context_used': used,
        'context_max': window,
        'context_percent': percent,
      });

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static int? _positive(Object? v) {
    final n = _asInt(v);
    return (n != null && n > 0) ? n : null;
  }

  /// Parse a reply payload. Tolerates missing sections, JSON-shaped strings,
  /// non-map category entries and negative counts; never throws.
  factory ContextBreakdown.fromPayload(Map? payload) {
    if (payload == null || payload.isEmpty) return empty;

    final window = _positive(payload['context_max']);
    final rawCategories = payload['categories'];
    final parsed = <({String id, String label, int tokens})>[];
    if (rawCategories is List) {
      for (final entry in rawCategories) {
        if (entry is! Map) continue;
        final id = entry['id']?.toString() ?? '';
        final label = entry['label']?.toString();
        parsed.add((
          id: id,
          label: (label == null || label.isEmpty) ? id : label,
          tokens: ContextCategory._tokensOf(entry['tokens']),
        ));
      }
    }
    final total = parsed.fold<int>(0, (sum, c) => sum + c.tokens);
    final categories = [
      for (final c in parsed)
        ContextCategory(
          id: c.id,
          label: c.label,
          tokens: c.tokens,
          shareOfTotal: total > 0 ? c.tokens / total : 0,
          shareOfWindow:
              window != null ? (c.tokens / window).clamp(0.0, 1.0) : null,
        ),
    ];

    final model = payload['model']?.toString();
    final source = payload['context_source']?.toString();
    return ContextBreakdown(
      categories: categories,
      used: _asInt(payload['context_used']),
      window: window,
      percent: _asInt(payload['context_percent'])?.clamp(0, 100),
      estimatedTotal: _asInt(payload['estimated_total']),
      model: (model == null || model.isEmpty) ? null : model,
      source: (source == null || source.isEmpty) ? null : source,
      estimated: payload['context_estimated'] == true,
    );
  }
}
