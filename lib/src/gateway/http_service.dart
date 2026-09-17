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
  Future<List<String>> authFlows() async {
    try {
      final res = await _client
          .get(Uri.parse(config.httpUrl('/api/status')), headers: _headers())
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      final body = _tryJson(res.body);
      final flows = body?['auth_flows'];
      if (flows is! List) return const [];
      return flows.map((e) => e.toString()).toList();
    } catch (_) {
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
