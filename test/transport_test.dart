import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/gateway/http_service.dart';

void main() {
  test('connection probe rejects healthy HTTP with rejected WS', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      if (r.uri.path == '/api/health') {
        r.response.write('{"ok":true}');
      } else { r.response.statusCode = 403; }
      await r.response.close();
    });
    final http = GatewayHttp(GatewayConfig(url: 'http://127.0.0.1:${server.port}'));
    try { expect((await http.testConnection()).ok, false); }
    finally { http.close(); await server.close(force: true); }
  });
  test('failed OAuth ticket never falls back to unauthenticated WS', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var upgrades = 0;
    server.listen((r) async {
      if (r.uri.path == '/api/auth/ws-ticket') {
        r.response.statusCode = 401;
        await r.response.close();
      } else {
        upgrades++;
        final ws = await WebSocketTransformer.upgrade(r);
        ws.listen((_) {});
      }
    });
    final client = GatewayClient(GatewayConfig(url: 'http://127.0.0.1:${server.port}', oauthToken: 'expired'));
    try {
      await expectLater(client.connect(), throwsA(isA<GatewayError>()));
      expect(upgrades, 0);
    } finally { await client.dispose(); await server.close(force: true); }
  });
  test('OAuth dials mint fresh tickets and preserve proxy headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var minted = 0;
    final tickets = <String?>[];
    server.listen((r) async {
      expect(r.headers.value('x-proxy'), 'test');
      if (r.uri.path == '/api/auth/ws-ticket') {
        expect(r.headers.value('authorization'), 'Bearer oauth');
        r.response.write(jsonEncode({'ticket': 'ticket-${++minted}'}));
        await r.response.close();
      } else {
        tickets.add(r.uri.queryParameters['ticket']);
        final ws = await WebSocketTransformer.upgrade(r);
        ws.listen((_) {});
      }
    });
    final client = GatewayClient(GatewayConfig(url: 'http://127.0.0.1:${server.port}', oauthToken: 'oauth', headers: {'x-proxy': 'test'}));
    try {
      await client.connect();
      client.close();
      await client.connect();
      expect(tickets, ['ticket-1', 'ticket-2']);
    } finally { await client.dispose(); await server.close(force: true); }
  });
}
