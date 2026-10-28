import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'config.dart';
import 'client.dart';

class ProbeResult {
  const ProbeResult({
    required this.ok,
    this.version,
    this.authRequired = false,
    this.detail = '',
  });
  final bool ok;
  final String? version;
  final bool authRequired;
  final String detail;

  String get summary => ok
      ? 'Gateway reachable${version != null ? ' (v$version)' : ''}${authRequired ? ' · OAuth gated' : ''}'
      : 'Unreachable: $detail';
}

/// Read-only HTTP checks against the gateway (public endpoints only —
/// `PUBLIC_API_PATHS`), used by the connect screen before opening the WS.
class GatewayHttp {
  GatewayHttp(this.config, {http.Client? client})
      : _client = client ?? _buildClient();

  final GatewayConfig config;
  final http.Client _client;

  void close() => _client.close();

  static http.Client _buildClient() {
    final hc = HttpClient()..userAgent = 'Talaria/1.0';
    return IOClient(hc);
  }

  Map<String, String> _headers() => config.authHeaders;

  /// GET /api/health — public liveness probe.
  Future<ProbeResult> health() async {
    try {
      final res = await _client
          .get(Uri.parse(config.httpUrl('/api/health')), headers: _headers())
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final body = _tryJson(res.body);
        return ProbeResult(
          ok: true,
          version: body?['version'] as String?,
          authRequired: body?['auth_required'] == true,
        );
      }
      return ProbeResult(ok: false, detail: 'HTTP ${res.statusCode}');
    } catch (e) {
      return ProbeResult(ok: false, detail: _netError(e));
    }
  }

  /// GET /api/status — richer public probe (version, gateway state).
  Future<ProbeResult> status() async {
    try {
      final res = await _client
          .get(Uri.parse(config.httpUrl('/api/status')), headers: _headers())
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final body = _tryJson(res.body);
        return ProbeResult(
          ok: true,
          version: body?['version'] as String?,
          authRequired: body?['auth_required'] == true,
        );
      }
      if (res.statusCode == 401) {
        return ProbeResult(
            ok: false, authRequired: true, detail: '401 — auth required');
      }
      return ProbeResult(ok: false, detail: 'HTTP ${res.statusCode}');
    } catch (e) {
      return ProbeResult(ok: false, detail: _netError(e));
    }
  }

  /// The gateway's advertised auth flows (public /api/status `auth_flows`).
  /// Returns an empty list when the gateway predates the field.
  /// [throwOnTransportError] distinguishes "the gateway did not answer"
  /// (throw, so a caller can retry a gateway that is still starting) from
  /// "it answered but advertises no flows" (empty list). Callers that only
  /// want the list keep the swallow-everything default.
  Future<List<String>> authFlows(
      {bool throwOnTransportError = false}) async {
    try {
      final res = await _client
          .get(Uri.parse(config.httpUrl('/api/status')), headers: _headers())
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        if (throwOnTransportError) {
          throw GatewayError('gateway answered /api/status with '
              'HTTP ${res.statusCode}');
        }
        return const [];
      }
      final body = _tryJson(res.body);
      final flows = body?['auth_flows'];
      if (flows is! List) return const [];
      return flows.map((e) => e.toString()).toList();
    } catch (_) {
      if (throwOnTransportError) rethrow;
      return const [];
    }
  }

  /// Mint a single-use WS ticket on a gated gateway. Requires a valid
  /// bearer token (native OAuth) or session cookie.
  Future<String?> mintWsTicket() async {
    if (config.oauthToken.isEmpty && config.bearerToken.isEmpty) return null;
    final res = await _client
        .post(Uri.parse(config.httpUrl('/api/auth/ws-ticket')),
            headers: _headers())
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 401) {
      // The auth gate answers 401 with a JSON body naming WHY (verified
      // against the gateway: hermes_cli/dashboard_auth/middleware.py
      // _unauth_response -> {error: session_expired|unauthenticated,
      // reason, login_url}). Discarding it (the old behavior) made a dead
      // credential look like a generic network failure, which fed the
      // endless reconnect loop and left the app unable to explain itself.
      final body = _tryJson(res.body);
      final kind = (body?['error'] ?? '').toString();
      throw GatewayAuthError(
        'Gateway rejected the stored sign-in (HTTP 401)',
        sessionExpired: kind == 'session_expired',
        reason: (body?['reason'] ?? '').toString(),
        loginUrl: body?['login_url']?.toString(),
      );
    }
    if (res.statusCode != 200) {
      throw HttpException('WS ticket HTTP ${res.statusCode}');
    }
    final ticket = _tryJson(res.body)?['ticket'];
    if (ticket is! String || ticket.isEmpty) {
      throw const FormatException('Gateway returned an invalid WS ticket');
    }
    return ticket;
  }

  /// Full connect test the desktop performs: HTTP probe + WS upgrade.
  Future<ProbeResult> testConnection() async {
    final h = await health();
    if (!h.ok) return h;
    if (h.authRequired && config.oauthToken.isEmpty && config.bearerToken.isEmpty) {
      return ProbeResult(
          ok: false,
          authRequired: true,
          detail:
              'Gateway requires sign-in. Add a token or use the OAuth flow.');
    }
    final ws = GatewayClient(config);
    try {
      await ws.connect();
      await ws.request('gateway.ping', const {}, 5000);
      return h;
    } catch (_) {
      return const ProbeResult(ok: false, detail: 'WebSocket authentication or RPC validation failed');
    } finally {
      await ws.dispose();
    }
  }

  static Map<String, dynamic>? _tryJson(String body) {
    try {
      final d = jsonDecode(body);
      return d is Map<String, dynamic> ? d : null;
    } catch (_) {
      return null;
    }
  }

  static String _netError(Object e) {
    if (e is SocketException) return e.osError?.message ?? e.message;
    if (e is TimeoutException) return 'timed out';
    return e.toString();
  }
}
