import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-level appearance preference (light / dark / auto).
///
/// This is a LOCAL UI setting and is deliberately separate from the gateway's
/// own `theme` config key (which themes the remote dashboard, not this app).
/// The owner (see `main.dart`) creates the [ValueNotifier<ThemeMode>] and
/// exposes it here; the Settings screen updates it via [ThemePreference.set],
/// which persists under [themeKey].
class ThemePreference extends InheritedNotifier<ValueNotifier<ThemeMode>> {
  const ThemePreference({
    super.key,
    required this.mode,
    required super.child,
  }) : super(notifier: mode);

  /// The live [ThemeMode] notifier. Mutate via [set].
  final ValueNotifier<ThemeMode> mode;

  /// Persistence key (SharedPreferences string: `light` | `dark` | `system`).
  static const themeKey = 'talaria.themeMode';

  static ThemePreference? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemePreference>();

  /// The live provider, or null when absent (e.g. a screen pumped in
  /// isolation in a widget test). Prefer [maybeOf] for optional lookups.
  static ThemePreference of(BuildContext context) => maybeOf(context)!;

  /// Parse a stored value. Unset/corrupt falls back to [system] (the caller's
  /// default is usually dark, so leave the notifier alone when nothing is set).
  static ThemeMode parse(String? raw) => switch (raw) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  /// Hydrate [notifier] from storage, leaving it untouched when unset.
  static Future<void> load(ValueNotifier<ThemeMode> notifier) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(themeKey);
      if (raw != null) notifier.value = parse(raw);
    } catch (_) {
      // Corrupt preference: keep the caller's default.
    }
  }

  /// Update the live theme and persist it.
  void set(ThemeMode m) {
    if (mode.value == m) return;
    mode.value = m;
    unawaited(_persist(m));
  }

  Future<void> _persist(ThemeMode m) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          themeKey,
          m == ThemeMode.light
              ? 'light'
              : m == ThemeMode.dark
                  ? 'dark'
                  : 'system');
    } catch (_) {
      // Persistence is best-effort; the in-memory value still applies.
    }
  }
}
