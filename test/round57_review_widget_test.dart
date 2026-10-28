import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/gateway/http_service.dart';
import 'package:talaria/src/screens/connection_screen.dart';
import 'package:talaria/src/store/app_model.dart';

void main() {
  setUp(() {
    AppModel.clientFactoryForTest = (cfg) => _FailClient(cfg);
  });
  tearDown(() {
    ConnectionScreen.httpFactoryForTest = null;
    AppModel.clientFactoryForTest = null;
  });

  testWidgets(
      'editing the gateway host does not send saved proxy secrets to it',
      (tester) async {
    final requests = <http.Request>[];
    ConnectionScreen.httpFactoryForTest =
        (cfg) => GatewayHttp(cfg, client: MockClient((req) async {
              requests.add(req);
              return http.Response('{}', 200);
            }));
    final model = AppModel(
        saved: GatewayConfig(
            url: 'https://trusted.example',
            headers: {'CF-Access-Client-Secret': 'private-proxy-secret'}));
    await tester.pumpWidget(MaterialApp(home: ConnectionScreen(model: model)));
    await tester.pump();
    await tester.enterText(
        find.byType(TextFormField).first, 'https://different.example');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();
    final newHostRequests =
        requests.where((r) => r.url.host == 'different.example').toList();
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    expect(newHostRequests, isNotEmpty);
    expect(newHostRequests.first.headers['CF-Access-Client-Secret'], isNull,
        reason:
            'discovery runs without explicit Connect consent and must not exfiltrate old host credentials');
  });

  testWidgets(
      'a failed discovery actually gets the promised single quiet retry',
      (tester) async {
    var requests = 0;
    ConnectionScreen.httpFactoryForTest =
        (cfg) => GatewayHttp(cfg, client: MockClient((req) async {
              requests++;
              if (requests == 1) throw http.ClientException('gateway starting');
              return http.Response('{"auth_flows":["native_pkce"]}', 200);
            }));
    final model = AppModel(saved: GatewayConfig(url: 'https://gw.example'));
    await tester.pumpWidget(MaterialApp(home: ConnectionScreen(model: model)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    final actual = requests;
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    expect(actual, 2,
        reason:
            'GatewayHttp.authFlows swallows the exception before the screen retry catch');
  });
  testWidgets('watchdog retry cannot let the older dial undo a newer success',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final firstDial = Completer<void>();
    var dials = 0;
    AppModel.clientFactoryForTest = (cfg) => _ControlledClient(
        cfg, ++dials == 1 ? firstDial.future : Future<void>.value());
    ConnectionScreen.httpFactoryForTest = (cfg) => GatewayHttp(cfg,
        client: MockClient((req) async => http.Response('{}', 200)));
    final model = AppModel();
    await tester.pumpWidget(MaterialApp(home: ConnectionScreen(model: model)));
    await tester.enterText(
        find.byType(TextFormField).first, 'https://gw.example');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 25));
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(model.phase, AppPhase.connected);
    firstDial.completeError(GatewayError('older dial finally timed out'));
    await tester.pump();
    final phase = model.phase;
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    expect(phase, AppPhase.connected,
        reason:
            'superseded failure must not navigate away from the live replacement');
  });
}

class _ControlledClient extends GatewayClient {
  _ControlledClient(super.config, this.dial);
  final Future<void> dial;
  @override
  Future<void> connect({bool isReconnect = false}) => dial;
  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    if (method == 'session.create') return {'session_id': 'new-live'};
    return {};
  }
}

class _FailClient extends GatewayClient {
  _FailClient(super.config);
  @override
  Future<void> connect({bool isReconnect = false}) async =>
      throw GatewayError('offline');
}
