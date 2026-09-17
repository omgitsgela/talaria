import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Material 3 theme for Talaria.  Warm-gold accent (caduceus gold) with
/// readable surfaces, consistent component tokens, and both dark and light
/// schemes that share shapes, typography, and radius tokens.
class AppTheme {
  static const _seed = Color(0xFFC9A227); // caduceus gold

  // ── Dark surfaces ─────────────────────────────────────────────────
  static const _dkBg = Color(0xFF0E0F13);
  static const _dkSurface = Color(0xFF16181E);
  static const _dkSurfaceLow = Color(0xFF1B1E24);
  static const _dkSurfaceHigh = Color(0xFF23262E);
  static const _dkSurfaceHighest = Color(0xFF2B2F38);

  // ── Light surfaces ────────────────────────────────────────────────
  static const _ltBg = Color(0xFFF8F9FB);
  static const _ltSurface = Color(0xFFFFFFFF);
  static const _ltSurfaceLow = Color(0xFFF5F6F8);
  static const _ltSurfaceHigh = Color(0xFFF0F1F4);
  static const _ltSurfaceHighest = Color(0xFFE8EAED);

  // ── Shared radii ──────────────────────────────────────────────────
  static const _rS = 12.0;
  static const _rM = 16.0;
  static const _rL = 20.0;

  // ── Public constructors ───────────────────────────────────────────

  /// Dark theme (default).  Deep blue-black background, warm gold accent,
  /// readable chat surfaces.
  static ThemeData dark() {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _seed,
        brightness: Brightness.dark,
        surface: _dkSurface,
      ).copyWith(
        surface: _dkSurface,
        surfaceContainerLow: _dkSurfaceLow,
        surfaceContainer: const Color(0xFF1E2028),
        surfaceContainerHigh: _dkSurfaceHigh,
        surfaceContainerHighest: _dkSurfaceHighest,
        onSurface: const Color(0xFFE8E9EB),
        onSurfaceVariant: const Color(0xFFA0A4AD),
        outline: const Color(0xFF3A3D44),
        outlineVariant: const Color(0xFF2C2F36),
      ),
      scaffoldBackgroundColor: _dkBg,
    );
    return _applyShared(base);
  }

  /// Light theme.  Clean off-white background with the same gold accent
  /// and shared component shapes.
  static ThemeData light() {
    final base = ThemeData(
      brightness: Brightness.light,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _seed,
        brightness: Brightness.light,
        surface: _ltSurface,
      ).copyWith(
        surface: _ltSurface,
        surfaceContainerLow: _ltSurfaceLow,
        surfaceContainer: _ltSurfaceHigh,
        surfaceContainerHigh: const Color(0xFFE5E7EB),
        surfaceContainerHighest: _ltSurfaceHighest,
        onSurface: const Color(0xFF1C1B1F),
        onSurfaceVariant: const Color(0xFF5F6368),
        outline: const Color(0xFFC4C7CC),
        outlineVariant: const Color(0xFFE0E2E6),
      ),
      scaffoldBackgroundColor: _ltBg,
    );
    return _applyShared(base);
  }

  // ── Shared component themes ───────────────────────────────────────

  static ThemeData _applyShared(ThemeData base) {
    final cs = base.colorScheme;
    final tt = base.textTheme;

    return base.copyWith(
      // AppBar: transparent, scrolled-under tint gives depth on scroll.
      // systemOverlayStyle keeps the status/nav bar text readable in both
      // brightnesses (edge-to-edge Android otherwise keeps a dark-adapted bar
      // in light mode).
      appBarTheme: AppBarTheme(
        backgroundColor: base.scaffoldBackgroundColor,
        elevation: 0,
        scrolledUnderElevation: 2,
        centerTitle: false,
        systemOverlayStyle: base.brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        titleTextStyle: tt.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
      ),

      // Cards: flat, rounded, surface-tinted.
      cardTheme: CardThemeData(
        elevation: 0,
        color: cs.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_rM),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      ),

      // Dialogs: elevated, rounded, high surface.
      dialogTheme: DialogThemeData(
        backgroundColor: cs.surfaceContainerHigh,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_rL),
        ),
        titleTextStyle: tt.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: cs.onSurface,
        ),
        contentTextStyle: tt.bodyMedium?.copyWith(
          color: cs.onSurfaceVariant,
        ),
      ),

      // SnackBars: floating, rounded, inverse surface.
      snackBarTheme: SnackBarThemeData(
        backgroundColor: cs.inverseSurface,
        contentTextStyle: tt.bodyMedium?.copyWith(
          color: cs.onInverseSurface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_rS),
        ),
        behavior: SnackBarBehavior.floating,
      ),

      // Text inputs: filled, rounded, visible focus ring.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cs.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_rS),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_rS),
          borderSide: BorderSide(color: cs.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_rS),
          borderSide: BorderSide(color: cs.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_rS),
          borderSide: BorderSide(color: cs.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_rS),
          borderSide: BorderSide(color: cs.error, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),

      // FilledButton: primary action.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_rS),
          ),
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),

      // ElevatedButton: secondary action.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_rS),
          ),
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),

      // TextButton: tertiary / inline action.
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_rS),
          ),
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
      ),

      // OutlinedButton: bordered secondary.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_rS),
          ),
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),

      // ListTile: consistent rounded hit targets.
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_rS),
        ),
      ),

      // Dividers: subtle, low-contrast.
      dividerTheme: DividerThemeData(
        color: cs.outlineVariant,
        thickness: 1,
        space: 1,
      ),

      // Popup menus: elevated, rounded, tinted.
      popupMenuTheme: PopupMenuThemeData(
        color: cs.surfaceContainerHigh,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_rS),
        ),
      ),

      // Segmented buttons: rounded.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_rS),
            ),
          ),
        ),
      ),
    );
  }
}
