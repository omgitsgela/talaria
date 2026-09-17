import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../gateway/config.dart';
import '../gateway/http_service.dart';
import '../gateway/oauth_flow.dart';
import 'chat_store.dart';

enum AppPhase { noConnection, connecting, connected }

/// App-level lifecycle: owns the active [ChatStore] (if any) and the
/// connection phase. `main.dart` creates one and the root widget
/// switches on [phase].
class AppModel extends ChangeNotifier {
  AppModel({
    GatewayConfig? saved,
    OAuthFlowRunner? oauthRunner,
    Future<void> Function(Uri url)? openBrowser,
  })  : _saved = saved,
        _phase = saved != null
            ? AppPhase.connecting
            : AppPhase.noConnection,
        _oauthRunner =
            oauthRunner ?? OAuthFlowRunner(store: OAuthTokenStore()),
        _openBrowser = openBrowser ?? _launchExternal {
    if (saved != null) {
      _connect(saved, notify: false);
    }
  }

  /// Open [url] in the system browser (custom tab on Android). The injectable
  /// seam lets tests substitute a fake browser without a platform channel.
  static Future<void> _launchExternal(Uri url) async {
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok) {
      throw Exception('Could not open a browser at $url');
    }
  }

  final OAuthFlowRunner _oauthRunner;
  final Future<void> Function(Uri url) _openBrowser;

  GatewayConfig? _saved;
  GatewayConfig? get saved => _saved;
  ChatStore? _store;
  ChatStore? get store => _store;
  AppPhase _phase = AppPhase.noConnection;
  AppPhase get phase => _phase;
  ProbeResult? _lastProbe;
  ProbeResult? get lastProbe => _lastProbe;

  /// True when the gateway at [c] advertises the native PKCE sign-in flow.
  Future<bool> supportsNativeSignin(GatewayConfig c) =>
      _oauthRunner.supportsNativeFlow(c);

  /// Run the Hermes native sign-in (RFC 8252 browser PKCE) against the
  /// gateway at [c]. Resolves an effective token via stored -> refreshed ->
  /// interactive, and returns a copy of [c] with the OAuth bearer set, ready
  /// to [connect]. [onStatus] receives short human status lines for the UI.
  Future<GatewayConfig> signInOAuth(
    GatewayConfig c, {
    void Function(String status)? onStatus,
  }) =>
      _oauthRunner
          .resolveToken(
            c,
            openBrowser: _openBrowser,
            onStatus: (s) {
              onStatus?.call(s);
              return s;
            },
          )
          .then((set) => c.copyWith(oauthToken: set.accessToken));

  /// Sign out of the Hermes native session for [c] (clears stored tokens).
  Future<void> signOutOAuth(GatewayConfig c) => _oauthRunner.signOut(c);

  /// Probe without connecting (for the connect screen).
  Future<ProbeResult> probe(GatewayConfig c) async {
    final r = await GatewayHttp(c).testConnection();
    _lastProbe = r;
    notifyListeners();
    return r;
  }

  /// Connect to [c]. On success, [phase] -> connected and [store] is live.
  Future<void> connect(GatewayConfig c) async {
    _saved = c;
    await _connect(c);
  }

  Future<void> _connect(GatewayConfig c, {bool notify = true}) async {
    if (notify) _setPhase(AppPhase.connecting);
    final store = ChatStore(config: c, oauthRunner: _oauthRunner);
    _store = store;
    try {
      await store.connect();
      _setPhase(AppPhase.connected);
    } catch (_) {
      _setPhase(AppPhase.noConnection);
      // Keep the store for error surfacing.
    }
  }

  void _setPhase(AppPhase p) {
    _phase = p;
    notifyListeners();
  }

  /// Leave the connected view back to the connection screen (store is
  /// torn down).
  void disconnect() {
    _phase = AppPhase.noConnection;
    _store?.dispose();
    _store = null;
    notifyListeners();
  }

  /// Save a new connection and switch to it (from Settings).
  Future<void> reconnect(GatewayConfig c) async {
    final store = ChatStore(config: c, oauthRunner: _oauthRunner);
    _store?.dispose();
    _store = store;
    _saved = c;
    _setPhase(AppPhase.connecting);
    try {
      await store.connect();
      _setPhase(AppPhase.connected);
    } catch (_) {
      _setPhase(AppPhase.noConnection);
    }
  }

  @override
  void dispose() {
    _store?.dispose();
    super.dispose();
  }
}
