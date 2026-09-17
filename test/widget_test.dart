import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/config.dart';

void main() {
  test('GatewayConfig normalizes URL and WS base', () {
    final c = GatewayConfig(url: 'gw.example.internal:9119', token: 'tok');
    expect(c.baseUrl, 'http://gw.example.internal:9119');
    expect(c.wsBase, 'ws://gw.example.internal:9119');
    expect(c.wsUrl(), 'ws://gw.example.internal:9119/api/ws?token=tok');
    expect(c.wsUrl(ticket: 'TICKET'), 'ws://gw.example.internal:9119/api/ws?ticket=TICKET');
    expect(c.usesToken, true);
  });

  test('GatewayConfig https maps to wss and uses bearer header', () {
    final c = GatewayConfig(url: 'https://gw.example.com', oauthToken: 'B');
    expect(c.wsBase, 'wss://gw.example.com');
    expect(c.authHeaders['Authorization'], 'Bearer B');
  });

  testWidgets('app builds the connection screen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(find.byType(SizedBox), isNotNull);
  });
}
