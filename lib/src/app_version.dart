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

/// `major.minor.patch` — shown as "Talaria 1.3.3".
///
/// This must move in step with the pubspec `version:` on every build. It had
/// been left at 1.2.6 while the pubspec moved to 1.3.2, so the splash screen,
/// the About row and the bug-report header all reported a version five builds
/// out of date. `round4_fixes_test` asserts the shape of the label rather than a
/// literal, which is why the drift went unnoticed; the shape check cannot catch
/// a version that simply never moved.
const String kAppVersion = '1.3.3';

/// Monotonic build number (matches the pubspec `+N`).
const int kAppBuildCode = 42;

/// One-line tagline for the splash.
const String kAppTagline = 'Your gateway, in your pocket';

/// `v1.1.0 (build 4)` — splash + About row.
String get kAppVersionLabel => 'v$kAppVersion (build $kAppBuildCode)';
