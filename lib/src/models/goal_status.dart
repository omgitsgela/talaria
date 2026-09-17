import 'dart:convert';

/// A long-horizon, session-scoped goal surfaced as a persistent status bar in
/// the conversation (mirrors the desktop's composer goal indicator).
///
/// A goal is set with `/goal <text>` and stays in scope across many turns until
/// cleared or achieved. The client reads its current state on demand by running
/// the read-only `slash.exec {command: 'goal status'}` RPC and parsing the first
/// line of the plain output — exactly what the Hermes desktop does.
class GoalStatus {
  GoalStatus({
    required this.status,
    required this.title,
    this.detail,
    required this.updatedAt,
  });

  /// One of [active], [waiting], [paused], [done].
  final String status;

  /// The goal's own text (what the user asked it to achieve).
  final String title;

  /// An optional secondary clause from the status line (e.g. a "3/20 turns"
  /// counter or a "next step" note) shown under the title.
  final String? detail;

  /// Wall-clock marker for change detection; not persisted.
  final DateTime updatedAt;

  bool get isActive => status == 'active';
  bool get isWaiting => status == 'waiting';
  bool get isPaused => status == 'paused';
  bool get isDone => status == 'done';
  bool get isTerminal => isDone;
}

/// Result of parsing a `goal status` output line. Mirrors the desktop's
/// tri-state (`null` clears, `undefined` keeps the prior state).
sealed class GoalParseResult {
  const GoalParseResult();
}

/// The input reports "no goal" (no active goal / cleared) → clear the bar.
class GoalParseNone extends GoalParseResult {
  const GoalParseNone();
}

/// The input carried an unrecognized line → keep the previous goal unchanged.
class GoalParseUnchanged extends GoalParseResult {
  const GoalParseUnchanged();
}

/// A goal is present in one of the known states → set/replace the bar.
class GoalParseValue extends GoalParseResult {
  GoalParseValue(this.goal);
  final GoalStatus goal;
}

/// Parse a `goal status` output string (or any transcript line that happens to
/// carry a goal status line) into a [GoalParseResult].
///
/// This is a direct port of the desktop's `nextGoalFromText`; the regexes map
/// 1:1 onto the gateway's `hermes_cli/goals.py` `goal status` output strings
/// (verified against the live gateway).
GoalParseResult parseGoalStatusText(String text) {
  final lines = const LineSplitter()
      .convert(text.trim())
      .where((l) => l.trim().isNotEmpty)
      .toList();
  final line = lines.isEmpty ? '' : lines.first;
  if (line.isEmpty) return const GoalParseUnchanged();

  // "No goal" family → clear.
  if (_none.hasMatch(line)) return const GoalParseNone();

  // Title-bearing status lines. Try each pattern in order; the FIRST one that
  // matches determines the state (no later pattern may overwrite it).
  final kinds = <(RegExp, String, bool)>[
    (_goalSet, 'active', true),
    (_goalActive, 'active', true),
    (_goalResumed, 'active', false),
    (_goalWaiting, 'waiting', true),
    (_goalPaused, 'paused', true),
    (_goalDone, 'done', true),
  ];
  String? status;
  String? title;
  String? detail;
  for (final (re, st, hasMeta) in kinds) {
    final mm = re.firstMatch(line);
    if (mm == null) continue;
    title = mm.group(1);
    status = st;
    detail = hasMeta ? _meta(line) : null;
    break;
  }

  if (title != null && status != null) {
    final s = status;
    final t = title;
    if (_clean(t) != '') {
      return GoalParseValue(GoalStatus(
        status: s,
        title: _clean(t),
        detail: detail,
        updatedAt: DateTime.now(),
      ));
    }
  }

  // Progressive "ticker" lines that carry no title of their own. The desktop
  // reuses the previous goal's title for these; without prior context here we
  // surface the whole clause as the title so the bar stays informative.
  var m = _continuing.firstMatch(line);
  if (m != null) {
    return GoalParseValue(GoalStatus(
      status: 'active',
      title: _clean(line.replaceFirst(RegExp(r'^↻\s*'), '')),
      updatedAt: DateTime.now(),
    ));
  }
  m = _parkedTicker.firstMatch(line);
  if (m != null) {
    return GoalParseValue(GoalStatus(
      status: 'waiting',
      title: _clean(line.replaceFirst(RegExp(r'^⏳\s*'), '')),
      updatedAt: DateTime.now(),
    ));
  }
  m = _pausedTicker.firstMatch(line);
  if (m != null) {
    return GoalParseValue(GoalStatus(
      status: 'paused',
      title: _clean(line.replaceFirst(RegExp(r'^⏸\s*'), '')),
      updatedAt: DateTime.now(),
    ));
  }
  m = _achievedTicker.firstMatch(line);
  if (m != null) {
    return GoalParseValue(GoalStatus(
      status: 'done',
      title: _clean(line.replaceFirst(RegExp(r'^✓\s*'), '')),
      updatedAt: DateTime.now(),
    ));
  }

  return const GoalParseUnchanged();
}

// ── Regexes (ported from the desktop store/goals.ts) ─────────────────────────
final RegExp _none = RegExp(
    r'^No active goal\b|^No goal (?:set|to resume)\b|^✓ Goal cleared\b',
    caseSensitive: false);
final RegExp _goalSet = RegExp(r'^⊙ Goal set(?:\s*\([^)]*\))?:\s*(.+)$');
final RegExp _goalActive = RegExp(r'^⊙ Goal\s*\([^)]*active[^)]*\):\s*(.+)$');
final RegExp _goalResumed = RegExp(r'^▶ Goal resumed:\s*(.+)$');
final RegExp _goalWaiting =
    RegExp(r'^⏳ Goal\s*\([^)]*(?:parked|active)[^)]*\):\s*(.+)$');
final RegExp _goalPaused = RegExp(r'^⏸ Goal(?:\s*\([^)]*\)| paused)?:\s*(.+)$');
final RegExp _goalDone = RegExp(r'^✓ Goal done\s*\([^)]*\):\s*(.+)$');
final RegExp _continuing =
    RegExp(r'^↻ Continuing toward goal\b', caseSensitive: false);
final RegExp _parkedTicker = RegExp(r'^⏳ Goal parked\b', caseSensitive: false);
final RegExp _pausedTicker = RegExp(r'^⏸ Goal paused\b', caseSensitive: false);
final RegExp _achievedTicker = RegExp(r'^✓ Goal achieved\b', caseSensitive: false);

String _clean(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

/// Extract the parenthetical meta (e.g. "3/20 turns") from a
/// "Goal (active, 3/20 turns): title" line, for the detail field.
String? _meta(String line) {
  final mm = RegExp(r'Goal\s*\(\s*\w+,\s*([^)]*)\s*\)').firstMatch(line);
  if (mm != null) {
    final g = mm.group(1);
    if (g != null && g.trim().isNotEmpty) return g.trim();
  }
  return null;
}
