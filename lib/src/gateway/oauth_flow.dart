import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'native_oauth.dart';

/// Encrypted store for native-OAuth token sets, keyed by gateway URL.
///
/// Mirrors the desktop's native-token-store: one entry per gateway base URL,
/// written with flutter_secure_storage (EncryptedSharedPreferences on Android).
class OAuthTokenStore {
  OAuthTokenStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _keyPrefix = 'talaria.oauth.';

  String _keyFor(String baseUrl) {
    final uri = Uri.parse(baseUrl);
    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    return '${_keyPrefix}${uri.scheme}://${uri.host}:${uri.port}$path';
  }

  Future<NativeTokenSet?> load(String baseUrl) async {
    try {
      final raw = await _storage.read(key: _keyFor(baseUrl));
      if (raw == null || raw.isEmpty) return null;
      return NativeTokenSet.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Corrupt/legacy entry: drop so the next sign-in starts clean.
      await _delete(baseUrl);
      return null;
    }
  }

  Future<void> save(String baseUrl, NativeTokenSet set) =>
      _storage.write(key: _keyFor(baseUrl), value: jsonEncode(set.toJson()));

  Future<void> _delete(String baseUrl) async {
    try {
      await _storage.delete(key: _keyFor(baseUrl));
    } catch (_) {}
  }

  Future<void> clear(String baseUrl) => _delete(baseUrl);
}

/// Runs the full RFC 8252 native sign-in against a gateway that advertises
/// `native_pkce`:
///   1. Bind a loopback HTTP listener on 127.0.0.1:<ephemeral>.
///   2. Generate the PKCE pair + CSRF state, build /auth/native/authorize.
///   3. Open the system browser (caller-provided [openBrowser]).
///   4. Receive the redirect, validate state, redeem the code via
///      POST /auth/native/token {code, code_verifier}.
///   5. Persist the token set in secure storage, return it.
///
/// Pure logic (PKCE, URL building, callback parsing, token parsing) lives in
/// [NativeOAuthService]; this class owns only the I/O coordination.
class OAuthFlowRunner {
  OAuthFlowRunner({
    required this.store,
    http.Client? httpClient,
    Duration timeout = const Duration(minutes: 2),
  }) : _http = httpClient ?? http.Client(),
       _timeout = timeout;

  final OAuthTokenStore store;
  final http.Client _http;
  final Duration _timeout;

  /// True when the gateway advertises the native PKCE flow.
  Future<bool> supportsNativeFlow(GatewayConfig config) async {
    final flows = await _statusFlows(config);
    return NativeOAuthService.flowsSupportNativeFlow(flows);
  }

  Future<List<String>> _statusFlows(GatewayConfig config) async {
    try {
      final res = await _http
          .get(Uri.parse(config.httpUrl('/api/status')),
              headers: config.headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(res.body);
      final flows = body is Map ? body['auth_flows'] : null;
      if (flows is! List) return const [];
      return flows.map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Run the sign-in. [openBrowser] must launch the system browser at [url]
  /// (e.g. via url_launcher). Resolves with the stored token set; throws
  /// [OAuthException] on any failure.
  Future<NativeTokenSet> signIn(
    GatewayConfig config, {
    required Future<void> Function(Uri url) openBrowser,
    FutureOr<String> Function(String status)? onStatus,
  }) async {
    final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final verifier = NativeOAuthService.generateVerifier();
    final challenge = NativeOAuthService.challengeFromVerifier(verifier);
    final state = NativeOAuthService.generateState();
    final redirectUri = Uri.parse('http://127.0.0.1:$port/callback');
    final authorizeUrl = NativeOAuthService.buildAuthorizeUrl(
      baseUrl: config.baseUrl,
      challenge: challenge,
      redirectUri: redirectUri.toString(),
      state: state,
    );

    final callback = Completer<Uri>();
    late StreamSubscription sub;
    sub = server.listen((req) async {
      final path = req.uri.path;
      if (path != '/callback') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      if (!callback.isCompleted) callback.complete(req.uri);
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.html;
      req.response.write('<html><body><h3>Talaria sign-in received.</h3>'
          '<p>You can close this tab and return to the app.</p></body></html>');
      await req.response.close();
    });

    try {
      onStatus?.call('Opening browser for Hermes sign-in…');
      await openBrowser(authorizeUrl);
      final callbackUri =
          await callback.future.timeout(_timeout, onTimeout: () =>
              throw const OAuthException(
                  'Timed out waiting for the browser sign-in callback'));

      onStatus?.call('Exchanging code for tokens…');
      final code = NativeOAuthService.parseLoopbackCallback(
          callbackUri: callbackUri, expectedState: state);

      final tokenBody = await _http
          .post(
            NativeOAuthService.buildTokenUrl(config.baseUrl),
            headers: {
              'content-type': 'application/json',
              ...config.headers,
            },
            body: jsonEncode({
              'code': code,
              'code_verifier': verifier,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (tokenBody.statusCode != 200) {
        throw OAuthException(
            'Gateway token endpoint returned HTTP ${tokenBody.statusCode}');
      }
      final parsed = jsonDecode(tokenBody.body);
      if (parsed is! Map<String, dynamic>) {
        throw const OAuthException('Malformed token response');
      }
      final tokens = NativeOAuthService.parseTokenResponse(parsed);
      await store.save(config.baseUrl, tokens);
      return tokens;
    } finally {
      await sub.cancel();
      await server.close(force: true);
    }
  }

  /// Refresh an expired/soon-expired token set via
  /// POST /auth/native/refresh {refresh_token, provider}. The gateway
  /// rotates the refresh token on success; on a 401 `session_expired`
  /// body it clears the stored set so the next connect starts fresh.
  Future<NativeTokenSet?> refresh(
    String baseUrl,
    NativeTokenSet set, {
    FutureOr<String> Function(String status)? onStatus,
    Map<String, String> headers = const {},
  }) async {
    if (set.refreshToken.isEmpty) return null;
    onStatus?.call('Refreshing session…');
    final res = await _http
        .post(
          NativeOAuthService.buildRefreshUrl(baseUrl),
          headers: {
            'content-type': 'application/json',
            ...headers,
          },
          body: jsonEncode({
            'refresh_token': set.refreshToken,
            'provider': set.provider,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 401) {
      // Session expired — drop the stale set; caller should re-auth.
      await store.clear(baseUrl);
      return null;
    }
    if (res.statusCode != 200) {
      throw OAuthException(
          'Token refresh failed (HTTP ${res.statusCode}); sign in again');
    }
    final parsed = jsonDecode(res.body);
    if (parsed is! Map<String, dynamic>) {
      throw const OAuthException('Malformed refresh response');
    }
    final refreshed = NativeOAuthService.parseTokenResponse(parsed);
    await store.save(baseUrl, refreshed);
    return refreshed;
  }

  Future<void> signOut(GatewayConfig config) =>
      store.clear(config.baseUrl);

  /// Resolve an effective access token for [config] using the desktop's
  /// "stored -> refreshed -> interactive" chain:
  ///   1. A stored token set that is still valid is used as-is.
  ///   2. A stored set that is expired/soon-expired is refreshed (rotation);
  ///      a 401 drops it.
  ///   3. Otherwise run the interactive browser sign-in.
  /// [openBrowser] launches the system browser; [onStatus] gets status lines.
  Future<NativeTokenSet> resolveToken(
    GatewayConfig config, {
    required Future<void> Function(Uri url) openBrowser,
    FutureOr<String> Function(String status)? onStatus,
  }) async {
    final base = config.baseUrl;
    final stored = await store.load(base);
    if (stored != null) {
      if (!NativeOAuthService.tokenNeedsRefresh(stored,
          nowSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000)) {
        return stored;
      }
      try {
        final refreshed = await refresh(base, stored, onStatus: onStatus, headers: config.headers);
        if (refreshed != null) return refreshed;
        // 401 path already cleared the stale set — fall through to re-auth.
      } on OAuthException {
        // Refresh endpoint unreachable / errored; fall through to re-auth.
      }
    }
    return signIn(config, openBrowser: openBrowser, onStatus: onStatus);
  }
}
