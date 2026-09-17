import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app_scope.dart';
import 'src/diagnostics/error_report.dart';
import 'src/gateway/client.dart';
import 'src/gateway/config.dart';
import 'src/notifications/notifier.dart';
import 'src/screens/connection_screen.dart';
import 'src/screens/home_screen.dart';
import 'src/screens/splash_screen.dart';
import 'src/store/app_model.dart';
import 'src/theme/app_theme.dart';
import 'src/theme/markdown_preference.dart';
import 'src/theme/theme_preference.dart';

/// The entire connection (including URL and proxy headers) is encrypted at rest.
/// Old plaintext records are deleted, not silently trusted or migrated.
class ConnectionPersistence {
  ConnectionPersistence({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const key = 'talaria.connection';

  Future<GatewayConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(key))
      throw StateError('Could not remove legacy credentials');
    final raw = await _storage.read(key: key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final config =
          GatewayConfig.fromMap(jsonDecode(raw) as Map<String, dynamic>);
      if (config.url.trim().isEmpty) throw const FormatException();
      return config;
    } catch (_) {
      await _storage.delete(key: key);
      return null;
    }
  }

  Future<void> save(GatewayConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(key))
      throw StateError('Could not remove legacy credentials');
    await _storage.write(key: key, value: jsonEncode(config.toMap()));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Debug builds: capture framework errors into a copyable report (the Android
  // red screen offers nothing to copy, which makes render-tree bugs
  // undiagnosable without adb logcat) and trace GlobalKey reparenting.
  ErrorReport.install();
  final persistence = ConnectionPersistence();
  GatewayConfig? saved;
  var loadFailed = false;
  try {
    saved = await persistence.load();
  } catch (_) {
    loadFailed = true;
  }
  runApp(TalaryApp(
      model: AppModel(saved: saved),
      persistence: persistence,
      ownsModel: true,
      storageWarning: loadFailed,
      showSplash: true));
}

class TalaryApp extends StatefulWidget {
  const TalaryApp(
      {super.key,
      required this.model,
      this.persistence,
      this.ownsModel = false,
      this.storageWarning = false,
      this.showSplash = false});
  final AppModel model;
  final ConnectionPersistence? persistence;
  final bool ownsModel;
  final bool storageWarning;

  /// Play the ~1s branded launch splash over the real app. Production
  /// [main] enables it; anything else (tests, embeds) leaves it off.
  final bool showSplash;
  @override
  State<TalaryApp> createState() => _TalaryAppState();
}

class _TalaryAppState extends State<TalaryApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _notifier = TalariaNotifier();
  String? _lastSaved;
  Future<void> _writes = Future.value();

  /// Local app appearance (separate from the gateway's own `theme` key).
  /// Persisted by [ThemePreference]; defaults to dark (the app's original
  /// look) so an unset preference never surprises overnight users.
  final ValueNotifier<ThemeMode> _themeMode =
      ValueNotifier<ThemeMode>(ThemeMode.dark);

  /// Local "render Markdown in replies" preference. Defaults to ON (the point
  /// of the feature); an explicit off reverts assistant bubbles to plain text.
  /// Flipping it rebuilds the connected subtree so every transcript bubble
  /// re-reads the value (see the MarkdownPreference-wrapped ListenableBuilder
  /// in [build]).
  final ValueNotifier<bool> _markdownEnabled = ValueNotifier<bool>(true);

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_changed);
    TalariaNotifier.pendingSession.addListener(_routeNotification);
    unawaited(_notifier.init());
    unawaited(ThemePreference.load(_themeMode));
    unawaited(MarkdownPreference.load(_markdownEnabled));
    _changed();
    if (widget.storageWarning) _warn();
  }

  void _warn() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _messenger.currentState?.showSnackBar(const SnackBar(
          content: Text(
              'Secure connection storage is unavailable. Credentials may need to be entered again.')));
    });
  }

  void _changed() {
    final model = widget.model;
    final config = model.saved;
    if (model.phase == AppPhase.connected &&
        config != null &&
        widget.persistence != null) {
      final snapshot = jsonEncode(config.toMap());
      if (snapshot != _lastSaved) {
        _lastSaved = snapshot;
        final persistence = widget.persistence!;
        _writes = _writes.then((_) async {
          try {
            await persistence.save(GatewayConfig.fromMap(
                jsonDecode(snapshot) as Map<String, dynamic>));
          } catch (_) {
            if (_lastSaved == snapshot) _lastSaved = null;
            _warn();
          }
        });
      }
    }
    _routeNotification();
  }

  /// Route a tapped conversation notification. The tap parks its STORED
  /// session id in [TalariaNotifier.pendingSession] and this drains it — but
  /// only when the socket is actually open. If the tap lands while the
  /// client is dialing/reconnecting, the id STAYS PARKED and this method is
  /// retried on every app-model change (phase flips, store notifies), so a
  /// slow reconnect never drops the navigation.
  void _routeNotification() {
    final id = TalariaNotifier.pendingSession.value;
    final store = widget.model.store;
    if (id == null ||
        widget.model.phase != AppPhase.connected ||
        store == null ||
        store.connection != GwConnectionState.open) {
      // Not routable YET — leave the payload parked for the next change.
      return;
    }
    TalariaNotifier.pendingSession.value = null;
    // Never reset a live turn by resuming the session already on screen. The
    // routing id is a STORED session id (that is what a notification payload
    // carries), so compare against the stored id — the runtime session id is
    // a different space and would never match.
    if (id != store.activeStoredSessionId) {
      unawaited(store.resumeSession(id));
    }
  }

  @override
  void didUpdateWidget(TalaryApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_changed);
      if (oldWidget.ownsModel) oldWidget.model.dispose();
      widget.model.addListener(_changed);
      _lastSaved = null;
      _changed();
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_changed);
    TalariaNotifier.pendingSession.removeListener(_routeNotification);
    _notifier.dispose();
    _themeMode.dispose();
    _markdownEnabled.dispose();
    if (widget.ownsModel) widget.model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ThemePreference(
        mode: _themeMode,
        child: MarkdownPreference(
          enabled: _markdownEnabled,
          child: ListenableBuilder(
            // Rebuild the connected subtree when EITHER the theme or the
            // markdown toggle flips. (InheritedNotifier alone would only
            // rebuild dependents when the notifier *instance* changes, not
            // when its value does.)
            listenable: Listenable.merge([_themeMode, _markdownEnabled]),
            builder: (context, _) {
              final app = AppScope(
                model: widget.model,
                child: MaterialApp(
                  title: 'Talaria',
                  debugShowCheckedModeBanner: false,
                  scaffoldMessengerKey: _messenger,
                  theme: AppTheme.light(),
                  darkTheme: AppTheme.dark(),
                  themeMode: _themeMode.value,
                  home: _Root(model: widget.model),
                ),
              );
              return widget.showSplash
                  ? SplashOverlay(child: app)
                  : app;
            },
          ),
        ),
      );
}

class _Root extends StatelessWidget {
  const _Root({required this.model});
  final AppModel model;
  @override
  Widget build(BuildContext context) => ConsumerModel(
      model: model,
      builder: (context, model) {
        final store = model.store;
        // Once AppModel has established a store, keep the Home shell mounted
        // across transient closed/error/reconnecting states. HomeScreen listens
        // directly to ChatStore and exposes the live Reconnect action; gating
        // this on `store.connection == open` made that action vulnerable to any
        // unrelated root rebuild while the socket was down.
        if (model.phase == AppPhase.connected && store != null) {
          return const HomeScreen();
        }
        return ConnectionScreen(model: model, onConnected: () {});
      });
}

class ConsumerModel extends StatelessWidget {
  const ConsumerModel({super.key, required this.model, required this.builder});
  final AppModel model;
  final Widget Function(BuildContext, AppModel) builder;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: model, builder: (context, _) => builder(context, model));
}
