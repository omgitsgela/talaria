import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-level toggle for rendering assistant messages as rich Markdown.
///
/// This is a LOCAL UI setting (mirrors [ThemePreference]) and is deliberately
/// separate from any gateway config key. Owner ([main.dart]) creates the
/// [ValueNotifier<bool>] and exposes it here; the Settings screen flips it via
/// [MarkdownPreference.set], which persists under [markdownKey].
///
/// Default is ON (the point of the feature). An explicitly-stored `false`
/// reverts assistant bubbles to plain selectable text.
class MarkdownPreference extends InheritedNotifier<ValueNotifier<bool>> {
  const MarkdownPreference({
    super.key,
    required this.enabled,
    required super.child,
  }) : super(notifier: enabled);

  /// The live "render Markdown" notifier. Mutate via [set].
  final ValueNotifier<bool> enabled;

  /// Persistence key (SharedPreferences string: `true` | `false`).
  static const markdownKey = 'talaria.markdown';

  static MarkdownPreference? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MarkdownPreference>();

  /// The live provider, or null when absent (a screen pumped in isolation).
  /// Prefer [maybeOf] for optional lookups.
  static MarkdownPreference of(BuildContext context) => maybeOf(context)!;

  /// Parse a stored value. Anything other than an explicit off is treated as
  /// ON, so a missing/corrupt preference keeps the richer default.
  static bool parse(String? raw) => !(raw == 'false' || raw == '0');

  /// Hydrate [notifier] from storage, leaving it at the default (ON) when the
  /// owner has never toggled it.
  static Future<void> load(ValueNotifier<bool> notifier) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(markdownKey);
      if (raw != null) notifier.value = parse(raw);
    } catch (_) {
      // Corrupt preference: keep the caller's default (ON).
    }
  }

  /// Update the live flag and persist it.
  void set(bool v) {
    if (enabled.value == v) return;
    enabled.value = v;
    unawaited(_persist(v));
  }

  Future<void> _persist(bool v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(markdownKey, v ? 'true' : 'false');
    } catch (_) {
      // Persistence is best-effort; the in-memory value still applies.
    }
  }
}
