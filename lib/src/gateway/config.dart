/// Talaria gateway connection model.
///
/// Talaria talks to a Hermes `serve` backend over the tui_gateway
/// JSON-RPC/WebSocket API (same surface the desktop client uses via
/// apps/shared). Auth is the dashboard session token on the WS upgrade
/// query string (loopback/--insecure mode) or an OAuth bearer token
/// (gated public gateways).
class GatewayConfig {
  GatewayConfig({
    required this.url,
    this.token = '',
    this.oauthToken = '',
    this.bearerToken = '',
    Map<String, String>? headers,
  }) : headers = headers ?? const {};

  /// Gateway base URL, e.g. `http://gw.example.internal:9119`.
  String url;

  /// Dashboard session token (`X-Hermes-Session-Token` value / `?token=`).
  /// Used by loopback / `--insecure` gateways.
  String token;

  /// OAuth bearer token (RFC 8252 native flow). Sent as Authorization
  /// header on HTTP calls; used to mint WS tickets on gated gateways.
  String oauthToken;

  /// Optional static bearer token for API-gateway fronts.
  String bearerToken;

  /// Extra proxy headers (e.g. CF-Access-Client-Id/Secret) applied to
  /// every HTTP + WebSocket request.
  final Map<String, String> headers;

  String get baseUrl {
    var u = url.trim();
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);
    if (!u.contains('://')) u = 'http://$u';
    return u;
  }

  bool get usesToken => token.trim().isNotEmpty;
  bool get usesOAuth => oauthToken.trim().isNotEmpty;

  /// `wss://` for https origins, `ws://` otherwise.
  String get wsBase {
    final base = baseUrl;
    return base.startsWith('https')
        ? base.replaceFirst('https://', 'wss://')
        : base.replaceFirst('http://', 'ws://');
  }

  /// WebSocket URL for the tui_gateway sidecar. [ticket] is a fresh
  /// single-use OAuth ticket (gated gateways); otherwise the legacy
  /// `?token=` parameter.
  String wsUrl({String? ticket}) {
    final qp = <String, String>{};
    if (ticket != null && ticket.isNotEmpty) {
      qp['ticket'] = ticket;
    } else if (usesToken) {
      qp['token'] = token;
    }
    final qs = qp.isEmpty ? '' : '?${Uri(queryParameters: qp).query}';
    return '${wsBase}/api/ws$qs';
  }

  String httpUrl(String path) {
    final p = path.startsWith('/') ? path : '/$path';
    return '$baseUrl$p';
  }

  /// Headers for HTTP requests (and, where the transport allows, WS).
  Map<String, String> get authHeaders {
    final h = <String, String>{...headers};
    if (usesOAuth) {
      h['Authorization'] = 'Bearer $oauthToken';
    } else if (bearerToken.isNotEmpty) {
      h['Authorization'] = 'Bearer $bearerToken';
    } else if (usesToken) {
      h['X-Hermes-Session-Token'] = token;
    }
    return h;
  }

  Map<String, dynamic> toMap() => {
        'url': url,
        'token': token,
        'oauthToken': oauthToken,
        'bearerToken': bearerToken,
        'headers': headers,
      };

  factory GatewayConfig.fromMap(Map<String, dynamic> m) => GatewayConfig(
        url: (m['url'] ?? '') as String,
        token: (m['token'] ?? '') as String,
        oauthToken: (m['oauthToken'] ?? '') as String,
        bearerToken: (m['bearerToken'] ?? '') as String,
        headers: (m['headers'] is Map)
            ? (m['headers'] as Map).map(
                (k, v) => MapEntry(k.toString(), v.toString()))
            : null,
      );

  GatewayConfig copyWith({
    String? url,
    String? token,
    String? oauthToken,
    String? bearerToken,
    Map<String, String>? headers,
  }) =>
      GatewayConfig(
        url: url ?? this.url,
        token: token ?? this.token,
        oauthToken: oauthToken ?? this.oauthToken,
        bearerToken: bearerToken ?? this.bearerToken,
        headers: headers ?? this.headers,
      );
}
