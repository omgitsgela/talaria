import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

/// Pure RFC 8252 native-app OAuth helpers for the Hermes gateway.
///
/// The gateway brokers the flow: it is the authorization server to Talaria
/// and an OAuth client to the upstream IDP (Nous Portal). Talaria generates
/// its own PKCE pair, the gateway provides /auth/native/authorize and
/// /auth/native/token endpoints.
///
/// This class contains only pure logic — no HTTP, no browser, no platform
/// plugins. The actual browser-open + loopback callback need `url_launcher`
/// and a deep-link handler (noted as a dependency gap).
class NativeOAuthService {
  /// The gateway status field value that advertises the native PKCE flow.
  static const String nativeFlowId = 'native_pkce';

  /// Generate a PKCE verifier (43-char base64url, 32 random bytes).
  static String generateVerifier({Random? random}) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// S256 challenge from a verifier.
  static String challengeFromVerifier(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  /// Generate a CSRF state value (32 bytes base64url).
  static String generateState({Random? random}) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(24, (_) => rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Build the /auth/native/authorize URL the system browser opens.
  ///
  /// [baseUrl] is the gateway root (e.g. http://gw.example.internal:9119).
  /// [redirectUri] is the desktop/mobile loopback callback.
  /// [provider] is optional — omitted lets the gateway auto-select.
  static Uri buildAuthorizeUrl({
    required String baseUrl,
    required String challenge,
    required String redirectUri,
    required String state,
    String? provider,
  }) {
    final base = Uri.parse(baseUrl);
    final prefix = base.path.replaceAll(RegExp(r'/+$'), '');
    final params = <String, String>{
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'redirect_uri': redirectUri,
      'state': state,
    };
    if (provider != null && provider.isNotEmpty) {
      params['provider'] = provider;
    }
    return base.replace(
      path: '$prefix/auth/native/authorize',
      queryParameters: params,
    );
  }

  /// Build the /auth/native/token endpoint URL.
  static Uri buildTokenUrl(String baseUrl) {
    final base = Uri.parse(baseUrl);
    final prefix = base.path.replaceAll(RegExp(r'/+$'), '');
    return base.replace(path: '$prefix/auth/native/token');
  }

  /// Build the /auth/native/refresh endpoint URL.
  static Uri buildRefreshUrl(String baseUrl) {
    final base = Uri.parse(baseUrl);
    final prefix = base.path.replaceAll(RegExp(r'/+$'), '');
    return base.replace(path: '$prefix/auth/native/refresh');
  }

  /// Check whether a gateway /api/status body advertises native_pkce flow.
  static bool statusSupportsNativeFlow(Map<String, dynamic> statusBody) {
    final flows = statusBody['auth_flows'];
    if (flows is! List) return false;
    return flows.contains(nativeFlowId);
  }

  /// Check whether an already-fetched auth-flows list advertises native_pkce.
  static bool flowsSupportNativeFlow(Iterable<String> flows) =>
      flows.contains(nativeFlowId);

  /// Parse the loopback redirect the gateway sends the browser to.
  ///
  /// Returns the authorization code. Throws on error, missing code, or
  /// state mismatch (CSRF defense — RFC 6749 §10.12).
  static String parseLoopbackCallback({
    required Uri callbackUri,
    required String expectedState,
  }) {
    final error = callbackUri.queryParameters['error'];
    if (error != null) {
      final desc = callbackUri.queryParameters['error_description'] ?? '';
      throw OAuthException(
          'Gateway rejected native login: $error${desc.isNotEmpty ? " ($desc)" : ""}');
    }

    final code = callbackUri.queryParameters['code'] ?? '';
    if (code.isEmpty) {
      throw const OAuthException('Loopback callback missing authorization code');
    }

    final state = callbackUri.queryParameters['state'] ?? '';
    if (expectedState.isEmpty || state != expectedState) {
      throw const OAuthException(
          'Loopback callback state mismatch (possible CSRF)');
    }

    return code;
  }

  /// Normalize a /auth/native/token (or refresh) JSON response.
  static NativeTokenSet parseTokenResponse(Map<String, dynamic> body) {
    final accessToken = (body['access_token'] ?? '') as String;
    if (accessToken.isEmpty) {
      throw const OAuthException('Gateway token response missing access_token');
    }
    final expiresAt = body['expires_at'];
    return NativeTokenSet(
      accessToken: accessToken,
      refreshToken: (body['refresh_token'] ?? '') as String,
      expiresAt: expiresAt is num ? expiresAt.toInt() : 0,
      provider: (body['provider'] ?? '') as String,
      userId: (body['user_id'] ?? '') as String,
    );
  }

  /// True when a stored token set is at/near expiry.
  static bool tokenNeedsRefresh(NativeTokenSet tokens,
      {int nowSeconds = 0, int skewSeconds = 60}) {
    if (tokens.expiresAt <= 0) return true;
    return nowSeconds >= tokens.expiresAt - skewSeconds;
  }
}

class NativeTokenSet {
  const NativeTokenSet({
    required this.accessToken,
    this.refreshToken = '',
    this.expiresAt = 0,
    this.provider = '',
    this.userId = '',
  });

  final String accessToken;
  final String refreshToken;
  final int expiresAt;
  final String provider;
  final String userId;

  bool get isExpired => expiresAt > 0 &&
      DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt;

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt,
        'provider': provider,
        'userId': userId,
      };

  factory NativeTokenSet.fromJson(Map<String, dynamic> m) => NativeTokenSet(
        accessToken: (m['accessToken'] ?? '') as String,
        refreshToken: (m['refreshToken'] ?? '') as String,
        expiresAt: m['expiresAt'] is int ? m['expiresAt'] as int : 0,
        provider: (m['provider'] ?? '') as String,
        userId: (m['userId'] ?? '') as String,
      );
}

class OAuthException implements Exception {
  const OAuthException(this.message);
  final String message;
  @override
  String toString() => 'OAuthException: $message';
}
