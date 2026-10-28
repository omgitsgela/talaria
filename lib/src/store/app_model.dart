import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../gateway/client.dart';
import '../gateway/config.dart';
import '../gateway/http_service.dart';
import '../gateway/oauth_flow.dart';
import 'chat_store.dart';

enum AppPhase { noConnection, connecting, connected }

/// App-level lifecycle: owns the active [ChatStore] (if any) and the
/// connection phase. `main.dart` creates one and the root widget
/// switches on [phase].
class AppModel extends ChangeNotifier {
  /// Test seam: supply the gateway client the model's stores dial with, so
  /// widget tests can drive connect failures (including auth rejections)
  /// without a live socket — the widget-test binding stubs real HTTP.
  @visibleForTesting
  static GatewayClient Function(GatewayConfig config)? clientFactoryForTest;

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
  ///
  /// [forceInteractive] (default true) always opens the browser. An explicit
  /// tap on "Sign in" is the USER asking for a sign-in page; silently
  /// returning a cached token made the button look broken whenever a stored
  /// token existed but was rejected server-side (after a gateway restart) —
  /// the reported "the OAuth screen doesn't let you go to the sign in page".
  /// Automatic recovery paths do NOT use this method: the store refreshes
  /// stored tokens itself via the runner before dialing.
  Future<GatewayConfig> signInOAuth(
    GatewayConfig c, {
    void Function(String status)? onStatus,
    bool forceInteractive = true,
  }) =>
      _oauthRunner
          .resolveToken(
            c,
            openBrowser: _openBrowser,
            onStatus: (s) {
              onStatus?.call(s);
              return s;
            },
            forceInteractive: forceInteractive,
          )
          .then((set) => c.copyWith(oauthToken: set.accessToken));

  /// Abandon an in-flight browser sign-in (the user closed the browser tab,
  /// or the flow is stuck): frees the sign-in buttons immediately instead of
  /// leaving them disabled for the full callback timeout.
  Future<void> cancelSignIn() => _oauthRunner.cancelActiveSignIn();

  /// Sign out of the Hermes native session for [c] (clears stored tokens).
  Future<void> signOutOAuth(GatewayConfig c) => _oauthRunner.signOut(c);

  /// Re-authorize the CURRENT saved connection from inside the connected app
  /// (the Home connection sheet's "Sign in again"). Runs a fresh interactive
  /// sign-in and reconnects with the new credential. Returns true when the
  /// connection is back. The transcript and queued work survive in the store;
  /// only the socket is re-dialed.
  Future<bool> reauthSignIn({void Function(String status)? onStatus}) async {
    // The live store's config is the ground truth after a reconnect swapped
    // connections; _saved is the startup record. Prefer the live one.
    final c = _store?.config ?? _saved;
    if (c == null) return false;
    try {
      final resolved =
          await signInOAuth(c, onStatus: onStatus, forceInteractive: true);
      final store = _store;
      if (store != null) {
        // Redial the live transport with the fresh credential. The store's
        // transcript, queued work, and open conversation survive - only the
        // socket is replaced. (reconnect() would replace the whole store and
        // open a brand-new conversation, which is the Settings action, not a
        // reauth.)
        final ok = await store.reauthInPlace(resolved.oauthToken);
        if (ok) {
          _saved = store.config;
          _setPhase(AppPhase.connected);
        }
        return ok;
      }
      // No live store (edge case from the connect screen): full connect.
      await _connect(resolved);
      return _phase == AppPhase.connected;
    } catch (_) {
      return false;
    }
  }

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

  /// Identity for the CURRENT connect attempt. Every new connect/reconnect
  /// (and disconnect/dispose) bumps it, so a slow superseded dial's late
  /// completion can never publish a phase for a store it no longer owns:
  /// the watchdog's re-armed Connect starts a fresh attempt, and the old
  /// one's catch/success branches check this generation before touching
  /// the app state.
  int _connectGen = 0;

  Future<void> _connect(GatewayConfig c, {bool notify = true}) async {
    final gen = ++_connectGen;
    if (notify) _setPhase(AppPhase.connecting);
    // Dispose the store being REPLACED before building the new one. A failed
    // connect deliberately keeps its store for error surfacing - and that
    // store's client may still hold a scheduled backoff reconnect. Replacing
    // it without disposing left orphan retry loops dialing the old
    // credential forever.
    _store?.dispose();
    final store = ChatStore(
        config: c,
        oauthRunner: _oauthRunner,
        client: clientFactoryForTest?.call(c));
    _store = store;
    try {
      await store.connect();
      // A newer connect (or a disconnect) superseded this attempt while its
      // dial was in flight; publishing a phase now would hide the newer
      // store's state.
      if (gen != _connectGen) return;
      _setPhase(AppPhase.connected);
    } catch (_) {
      if (gen != _connectGen) return;
      _setPhase(AppPhase.noConnection);
      // Keep the store for error surfacing.
    }
  }

  /// The last connection attempt's failure, ready for the connect screen to
  /// render. Auth rejections arrive already explained (see ChatStore
  /// [ChatStore.reauthExplanation]); null when the last attempt succeeded or
  /// nothing has been tried yet.
  String? get connectError => _store?.connectError;

  /// True when the last failed attempt was the gateway REJECTING the
  /// credential - the connect screen shows "Sign in" guidance instead of a
  /// network-error wording.
  bool get needsReauth => _store?.needsReauth ?? false;

  void _setPhase(AppPhase p) {
    _phase = p;
    notifyListeners();
  }

  /// Leave the connected view back to the connection screen (store is
  /// torn down).
  void disconnect() {
    ++_connectGen;
    _phase = AppPhase.noConnection;
    _store?.dispose();
    _store = null;
    notifyListeners();
  }

  /// Save a new connection and switch to it (from Settings).
  Future<void> reconnect(GatewayConfig c) async {
    final gen = ++_connectGen;
    final store = ChatStore(
        config: c,
        oauthRunner: _oauthRunner,
        client: clientFactoryForTest?.call(c));
    _store?.dispose();
    _store = store;
    _saved = c;
    _setPhase(AppPhase.connecting);
    try {
      await store.connect();
      if (gen != _connectGen) return;
      _setPhase(AppPhase.connected);
    } catch (_) {
      if (gen != _connectGen) return;
      _setPhase(AppPhase.noConnection);
    }
  }

  @override
  void dispose() {
    ++_connectGen;
    _store?.dispose();
    super.dispose();
  }
}
