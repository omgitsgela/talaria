/// Current context-window occupancy for the active session.
///
/// Source of truth is the gateway's usage payload (`_get_usage` in
/// `tui_gateway/server.py`), which arrives nested under `usage` on
/// `session.info` and `message.complete`, and flat from a `session.usage`
/// request or event.
///
/// The gateway deliberately OMITS `context_used` / `context_max` when the
/// context engine cannot report a real current occupancy (for example right
/// after a compression, when it emits a -1 sentinel). An unknown reading must
/// therefore stay unknown so the UI shows nothing rather than a fake 0%.
///
/// The `session.context_breakdown` reply carries the SAME `context_used` /
/// `context_max` / `context_percent` keys on its top level, so a breakdown
/// payload parses through the same [ContextUsage.fromUsage] path: the
/// percentage here and the category breakdown never disagree about how the
/// numbers are read.
class ContextUsage {
  const ContextUsage({this.used, this.max, this.percent});

  /// Tokens currently occupying the window, when the gateway reports them.
  final int? used;

  /// The model's context window, when known.
  final int? max;

  /// Pre-computed fill percentage from the gateway, or derived locally.
  final int? percent;

  static const ContextUsage unknown = ContextUsage();

  bool get isKnown => used != null && used! > 0;

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  /// Parse a usage dict. Tolerates missing fields, strings from JSON, the
  /// `-1` "compression just ran" sentinel, and a max of 0/absent.
  factory ContextUsage.fromUsage(Map? usage) {
    if (usage == null || usage.isEmpty) return unknown;
    final rawUsed = _asInt(usage['context_used']);
    if (rawUsed == null || rawUsed <= 0) return unknown;
    final rawMax = _asInt(usage['context_max']);
    final max = (rawMax != null && rawMax > 0) ? rawMax : null;
    var percent = _asInt(usage['context_percent']);
    if (percent == null && max != null) {
      percent = ((rawUsed / max) * 100).round().clamp(0, 100);
    }
    if (percent != null) percent = percent.clamp(0, 100);
    return ContextUsage(used: rawUsed, max: max, percent: percent);
  }

  /// A `session.context_breakdown` reply carries the same occupancy keys at
  /// its top level; this is [fromUsage], named so a call site that holds a
  /// breakdown payload reads honestly.
  factory ContextUsage.fromBreakdown(Map? breakdown) =>
      ContextUsage.fromUsage(breakdown);

  /// Compact app-bar label: `24.5k/128k`, or just the used count when the
  /// window size is unknown. Null when there is nothing truthful to show.
  String? get label {
    if (!isKnown) return null;
    final u = formatTokenCount(used!);
    final m = max;
    return m == null ? u : '$u/${formatTokenCount(m)}';
  }

  /// Longer description for a tooltip or a details row.
  String? get description {
    if (!isKnown) return null;
    final m = max;
    final pct = percent;
    final of = m == null ? '' : ' of ${formatTokenCount(m)}';
    final pc = pct == null ? '' : ' ($pct%)';
    return 'Context: ${formatTokenCount(used!)}$of$pc';
  }

  @override
  bool operator ==(Object other) =>
      other is ContextUsage &&
      other.used == used &&
      other.max == max &&
      other.percent == percent;

  @override
  int get hashCode => Object.hash(used, max, percent);
}

/// `950` -> `950`, `12400` -> `12.4k`, `128000` -> `128k`, `1500000` -> `1.5m`.
String formatTokenCount(int n) {
  if (n < 0) return '0';
  if (n < 1000) return '$n';
  if (n < 100000) {
    // One decimal only when it carries information: 24500 -> 24.5k, 32000 -> 32k.
    final s = (n / 1000).toStringAsFixed(1);
    return s.endsWith('.0') ? '${s.substring(0, s.length - 2)}k' : '${s}k';
  }
  if (n < 1000000) return '${(n / 1000).round()}k';
  return '${(n / 1000000).toStringAsFixed(1)}m';
}
