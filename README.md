# Talaria

**Your gateway, in your pocket.**

Talaria is a Flutter mobile client for a self hosted [Hermes Agent](https://hermes-agent.nousresearch.com/docs)
gateway running in remote gateway mode. It talks to the gateway over HTTP and WebSocket,
so your phone becomes a second window onto the same conversations, tasks, and goals as the
desktop app.

This is an unofficial companion. It is not affiliated with or endorsed by Nous Research.

## Screenshots

| Launch | Conversation | Conversations | Settings |
|---|---|---|---|
| ![Launch splash](docs/screenshots/01-splash.png) | ![A conversation with a thinking trace, a tool call and the context readout](docs/screenshots/02-transcript.png) | ![The conversation list with pinning and time buckets](docs/screenshots/03-roster.png) | ![Settings and the model picker](docs/screenshots/04-settings.png) |

These are renders of the real widgets at phone size, regenerated with
`flutter test --update-goldens tool/screenshot_gen_test.dart`.

## Features

- **Live conversation streaming**, including thinking traces, tool activity, and ordered
  turn parts, with the transcript following the newest message as a reply arrives.
- **Conversation roster** with pinned chats and time buckets (Today / Yesterday / This
  week / This month / Older), plus per-conversation status dots and unread position.
- **Model switching per conversation** from the gateway's own model list, with
  provider aware routing, reasoning effort, fast mode, and trace visibility toggles.
- **Context readout in the app bar**, right of the model name: how much of the model's window
  the conversation is using (`24.5k/128k`), taken from the gateway's own usage report and kept
  hidden until that report carries a real measurement.
- **Rich Markdown** replies (selectable text, working links, themed code and blockquote
  panels) with a per-user render toggle.
- **Goals, todos, and slash commands** mirrored from the gateway, including a persistent
  goal bar and clarification or approval cards you can answer from the phone.
- **Cross client sync**: a conversation touched on the desktop or from a terminal updates
  here, because the app follows the gateway's session broadcasts.
- **Notifications** for completed turns and for requests that need your input.
- **Image and file attachments** staged through the gateway.
- **Recovery from backgrounding**: a conversation whose runtime session was reaped is
  re-attached silently, so the next send, Stop, and status indicators keep working.

## Requirements

- A running Hermes Agent gateway with its remote gateway surface reachable from the phone.
- A gateway token, or gateway OAuth if it is enabled.
- Flutter 3.22 or newer and a working Android toolchain to build.

## Build

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug        # build/app/outputs/flutter-apk/app-debug.apk
```

`flutter run` also works against a connected device or emulator.

The Android toolchain needs JDK 21. If your JDK is not the one Gradle would pick by
default, point Gradle at it outside the repository, for example in
`~/.gradle/gradle.properties`:

```properties
org.gradle.java.home=/path/to/jdk-21
```

## Install on Android (sideloading)

Talaria is not on Google Play. Install the APK from the
[Releases](https://github.com/omgitsgela/talaria/releases) page:

1. On the phone, open the release and download the `.apk` asset.
2. Tap the downloaded file. Android blocks installs from unknown sources by default, so the
   first attempt offers a settings shortcut: enable **Allow from this source** for whichever
   app downloaded it (your browser or file manager), then go back and tap **Install**.
3. Play Protect may warn that the developer is unknown. Choose **Install anyway**. That warning
   appears for anything installed outside Play.
4. Open Talaria, enter the gateway URL and token, and connect.

Notes:

- The APK is a **universal release build** (arm64-v8a, armeabi-v7a and x86_64), so it runs on
  any supported phone and on emulators.
- It is signed with the project's own **release key** (RSA 4096). The keystore is deliberately
  kept outside this repository and is never committed, so a clone cannot build a release APK that
  Android will accept as an update to a published one. Without `android/key.properties`, release
  builds fall back to the debug key, which is fine for local work and not for distribution.
- Android ties updates to the signing key, so an APK installed from this page can only be updated
  by another APK from this page. An F-Droid build is signed by F-Droid with its own key, so pick
  one source per device.
- Requires **Android 7.0 (API 24) or newer**.
- Your phone must be able to reach the gateway. A gateway on your own network means the same
  Wi-Fi network.

## Releases

Each tagged release carries a ready-to-install APK, its SHA-256, and the commit it was built
from. The APK is produced with `flutter build apk --release` from that tag.

## F-Droid

Preparation in progress, not yet submitted. F-Droid builds every app from source and signs it
with its own key, so the app's own signing key does not matter to them:

- Recipe: [`docs/fdroid/com.talaria.talaria.yml`](docs/fdroid/com.talaria.talaria.yml), the
  metadata file that gets submitted to
  [fdroiddata](https://gitlab.com/fdroid/fdroiddata).
- Already true of this project: open-source dependencies only (MIT, BSD and Apache-2.0), no
  tracking or analytics, no prebuilt binaries in the tree, and tagged releases whose commits
  build with `flutter build apk --release`.
- To submit: add the metadata file to a fork of `fdroiddata` under `metadata/` and open a merge
  request. F-Droid builds, signs and hosts the result.

## Configuration

Open the app, enter the gateway URL (for example `http://gateway.local:9119`) and your
token, and connect. The connection settings, including the token, are stored with
`flutter_secure_storage` (Android Keystore backed), not in plain preferences.

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
    models/                     conversation, message, tool and goal models,
                                including context_usage.dart for the app bar readout
    notifications/              foreground service and local notifications
    screens/                    connection, home (transcript), settings, splash
    store/
      chat_store.dart           application state: sessions, transcript, turns
      app_model.dart            app level state
    theme/                      theme, Markdown, and preference plumbing
    widgets/message_bubble.dart  one transcript row, memoized per revision
```

The app speaks the gateway's JSON RPC methods: `session.create`, `session.most_recent`,
`session.list`, `session.active_list`, `session.resume`, `session.history`,
`session.close`, `session.delete`, `prompt.submit`, `session.interrupt`, `slash.exec`,
`session.compress`, `config.get`, `config.set`, `clarify.respond`, and
`approval.respond`, plus the gateway's WebSocket event stream.

## Testing

```bash
flutter test
```

The suite covers the gateway transport contracts, transcript rendering and scrolling,
model and reasoning plumbing, session recovery, and the Markdown theming paths.

`tool/screenshot_gen_test.dart` regenerates the images in `docs/screenshots/` from the real
widgets. It lives outside `test/` on purpose, so `flutter test` never golden-compares the
screenshots and a UI change cannot fail CI because a picture is stale:

```bash
flutter test --update-goldens tool/screenshot_gen_test.dart
```

## Security notes

- `android:usesCleartextTraffic="true"` is enabled so the app can talk to a plain HTTP
  gateway on your own network. If your gateway is reachable beyond your LAN, put it
  behind TLS and use an `https://` URL.
- The app only connects to the gateway you configure. There is no telemetry and no
  third party analytics.

## Acknowledgements

Talaria is an independent client. It contains no Hermes Agent source code: it speaks the
gateway's documented JSON RPC and WebSocket protocol over the network.

- [Hermes Agent](https://hermes-agent.nousresearch.com/docs) by Nous Research, released
  under the MIT License, is the backend this app is built for.
- Several comments cite the gateway's own source paths (`tui_gateway/...`) and the desktop
  app's patterns (`apps/desktop/...`) so a reader can verify the protocol contract against
  the reference implementation. Those are citations, not copied code.

## License

MIT. See [LICENSE](LICENSE).
