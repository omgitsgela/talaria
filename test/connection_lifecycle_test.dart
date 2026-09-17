import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/store/app_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test('connect future waits for failure and exposes a retryable phase', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async { r.response.statusCode = 403; await r.response.close(); });
    final model = AppModel();
    try {
      await model.connect(GatewayConfig(url: 'http://127.0.0.1:${server.port}'));
      expect(model.phase, AppPhase.noConnection);
      expect(model.store?.connectError, isNotNull);
    } finally { model.dispose(); await server.close(force: true); }
  });
  test('saved startup completes its phase', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final ws = await WebSocketTransformer.upgrade(r);
      ws.listen((raw) {
        final f = jsonDecode(raw as String);
        ws.add(jsonEncode({'id': f['id'], 'result': {'sessions': [], 'session_id': null}}));
      });
    });
    final model = AppModel(saved: GatewayConfig(url: 'http://127.0.0.1:${server.port}'));
    try {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(model.phase, AppPhase.connected);
    } finally { model.dispose(); await server.close(force: true); }
  });
}
