# Contributing to Talaria

Everything in this file is for people who want to build, test, or release Talaria. If you just
want to use the app, the [README](README.md) is the place to start.

## Setting up

- **Flutter 3.22 or newer** (developed and released with 3.47.2) with Dart 3.4+.
- **A working Android toolchain**: the Android SDK, and **JDK 21**.
- The Android build uses `compileSdk 37` and relies on the version pinned in
  `android/settings.gradle.kts`. Flutter's Gradle plugin hard-fails below AGP 8.11.1, so if you
  bump Flutter and the build complains about plugin versions, update both versions there rather
  than fighting the misleading "AGP 9 new DSL" message Flutter prints.

If your JDK is not the one Gradle would pick by default, point Gradle at it outside the
repository, for example in `~/.gradle/gradle.properties`:

```properties
org.gradle.java.home=/path/to/jdk-21
```

## Build and run

```bash
flutter pub get
flutter analyze --no-fatal-infos   # warnings and errors fail, info lints are reported
flutter test
flutter build apk --debug          # build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release        # build/app/outputs/flutter-apk/app-release.apk
flutter run                        # against a connected device or emulator
```

## Tests

```bash
flutter test
```

The suite covers the gateway transport contracts, transcript rendering and scrolling, model and
reasoning plumbing, session recovery, deferred history reads during compaction, and the Markdown
theming paths. Treat a green suite as the baseline, not as proof that a gateway contract or a
device behaviour is correct: read the gateway's own handlers when changing protocol code, and
verify the exact payload shapes rather than assuming them.

Two habits that keep the tests honest:

- When you fix a bug, prove the test fails against the unfixed code before you trust it. A test
  that passes either way is worth nothing.
- Widget tests need a phone-sized surface. A bare `pumpWidget` gives an 800x600 logical canvas,
  which is wider than any phone and produces overflow failures that do not happen in reality. Set
  `tester.view.physicalSize = const Size(1260, 2700)` with
  `devicePixelRatio = 3.0` (420x900 logical) and reset it in `addTearDown`.

### Regenerating the screenshots

The images in `docs/screenshots/` are renders of the real widgets, not photographs or mockups.
They are produced by `tool/screenshot_gen_test.dart`, which is deliberately outside `test/`, so
`flutter test` never golden-compares them and a UI change cannot fail CI because a picture is
stale:

```bash
flutter test --update-goldens tool/screenshot_gen_test.dart
```

The generator loads Roboto and MaterialIcons from the local Flutter SDK using `FLUTTER_ROOT`, so
text and icons render as they do on a device. Keep the fixture data synthetic: no real
conversations, and no identifiers that look like genuine gateway session ids.

## Architecture

```
lib/
  main.dart                     app entry, connection persistence, notification routing
  src/
    app_scope.dart              app level dependency scope
    app_version.dart            version and build code shown in the UI
    diagnostics/error_report.dart  copyable crash reports for debug builds
    gateway/
      client.dart               JSON RPC + WebSocket transport, event stream
      config.dart               gateway URL / token model and URL derivation
      http_service.dart         HTTP side of the gateway surface
      native_oauth.dart         gateway OAuth handshake
      oauth_flow.dart           credential storage and refresh
    models/                     conversation, message, tool and goal models
    notifications/              foreground service and local notifications
    screens/                    connection, home (transcript), settings, splash
    store/
      chat_store.dart           application state: sessions, transcript, turns
      app_model.dart            app level state
    theme/                      theme, Markdown, and preference plumbing
    widgets/message_bubble.dart  one transcript row, memoized per revision
```

The app speaks the gateway's JSON RPC methods: `session.create`, `session.most_recent`,
`session.list`, `session.active_list`, `session.resume`, `session.history`, `session.close`,
`session.delete`, `session.title`, `prompt.submit`, `session.interrupt`, `slash.exec`,
`session.compress`, `config.get`, `config.set`, `clarify.respond`, and `approval.respond`, plus
the gateway's WebSocket event stream.

Notes that cost us time to learn, and are worth keeping:

- **Two id spaces.** `session.list` rows carry the *stored* session key, while
  `session.active_list` rows carry the *runtime* id (with the stored key in a separate field).
  Anything comparing against the on-screen conversation must use the stored key, never the runtime
  id.
- **An assistant turn streams interleaved.** Thinking, tool calls and response text arrive
  interleaved, so the message model keeps ordered parts. The authoritative writes from
  `message.interim` and `message.complete` replace the last *text* part, never the last part
  overall.
- **Compaction rewrites history mid-turn.** While a compaction is in flight, a history read can
  come back short, so history pulls are deferred until it reports completion.
- **`config.set model` is session scoped** and silently succeeds against an unresolvable session
  id on some gateway builds, so a model switch must make sure it has a live target first.

## Release process

1. Bump the version in **both** places: `pubspec.yaml` (`version: X.Y.Z+N`) and
   `lib/src/app_version.dart` (`kAppVersion`, `kAppBuildCode`). The convention is that
   `major.minor` moves for feature rounds and `+N` moves for every APK build.
   Bump the version *name* for a public release, not only the build code: F-Droid's tag based
   update check maps one tag to one version name, so two releases sharing a name cannot be told
   apart.
2. Update `CHANGELOG.md`.
3. Run `flutter analyze --no-fatal-infos` and `flutter test`, and build both APKs.
4. Verify the artifacts with `aapt2 dump badging` (package, `versionCode`, `versionName`, ABIs) and
   `apksigner verify --print-certs` (signer identity).
5. Commit, push, and tag the release.
6. Create the GitHub release with **both** assets, using the filenames people will actually
   download: `talaria-<version>.apk` and `talaria-<version>-debug.apk`. Stage each file under that
   exact name before uploading; the `#label` suffix that `gh` supports sets a display label only,
   so the asset keeps its original filename.
7. Verify by downloading both assets back from GitHub and re-hashing them against the local builds.

Build receipts (the notes describing each build, with hashes and verification) are kept out of
this repository on purpose, because they contain absolute paths and local network details.

### Signing

Release builds are signed with the project's own release key, read from `android/key.properties`
(not committed) with the keystore itself stored outside the repository. The certificate subject is
`CN=Talaria, O=Talaria contributors, C=US`, RSA 4096, valid to 2054, and the APK carries both the
v2 and v3 signature schemes.

You can confirm the identity of a published APK:

```bash
apksigner verify --print-certs talaria-1.1.1.apk
```

Two consequences worth understanding before changing anything here:

- **When `android/key.properties` is absent, release builds fall back to the Android debug key**, so
  a fresh clone still builds without the private key. That is convenient for local work and must
  never be used for a distributed APK.
- **Android ties updates to the signing key.** Changing the key means every existing install has to
  be uninstalled and reinstalled, so treat the keystore as permanent and back it up. A leaked key
  can be rotated; a lost key cannot be recovered.

### F-Droid

F-Droid builds every app from source and signs it with its own key, so the signing configuration
above does not affect that route. The submission recipe and the requirements it still has to meet
are in [`docs/fdroid/README.md`](docs/fdroid/README.md).

## Conventions

- Keep the protocol contract comments honest: where the app depends on a specific gateway
  behaviour, cite the gateway source path in a comment so the next reader can check it.
- Do not put machine specifics in the tree: no personal paths, LAN addresses, or real session ids
  in code, tests, or documentation. Use `gw.example.internal:9119`, `example.internal`, and
  `/home/user` in examples.
- The CHANGELOG describes user visible changes, not internal refactors.
