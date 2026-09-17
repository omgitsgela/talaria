/// App version constants.
///
/// Single source of truth for the version shown in the UI (splash +
/// Settings → About). `flutter.versionCode` / `flutter.versionName` in the
/// Android build also read these values from `pubspec.yaml` (`version:
/// X.Y.Z+code`) — when you bump the build, bump BOTH this file and the
/// pubspec so the package metadata, the store listing, and the UI never
/// disagree.
///
/// Convention (since the 2026-09-11 build round):
///   - major.minor  = user-facing feature rounds
///   - +code        = every APK build, incremented monotonically.
library;

/// `major.minor.patch` — shown as "Talaria 1.2.3".
const String kAppVersion = '1.2.3';

/// Monotonic build number (matches the pubspec `+N`).
const int kAppBuildCode = 32;

/// One-line tagline for the splash.
const String kAppTagline = 'Your gateway, in your pocket';

/// `v1.1.0 (build 4)` — splash + About row.
String get kAppVersionLabel => 'v$kAppVersion (build $kAppBuildCode)';
