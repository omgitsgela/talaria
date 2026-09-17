# Talaria

**Your gateway, in your pocket.**

Talaria is a Flutter mobile client for a self hosted [Hermes Agent](https://hermes-agent.nousresearch.com/docs)
gateway running in remote gateway mode. It talks to the gateway over HTTP and WebSocket,
so your phone becomes a second window onto the same conversations, tasks, and goals as the
desktop app.

This is an unofficial companion. It is not affiliated with or endorsed by Nous Research.

## Features

- **Live conversation streaming**, including thinking traces, tool activity, and ordered
  turn parts, with the transcript following the newest message as a reply arrives.
- **Conversation roster** with pinned chats and time buckets (Today / Yesterday / This
  week / This month / Older), plus per-conversation status dots and unread position.
- **Model switching per conversation** from the gateway's own model list, with
  provider aware routing, reasoning effort, fast mode, and trace visibility toggles.
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
