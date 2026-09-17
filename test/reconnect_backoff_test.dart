import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';

void main() {
  final cfg = GatewayConfig(url: 'http://127.0.0.1:9');

  group('reconnectDelay (full-jitter backoff)', () {
    test('is always within [0, min(cap, base*2^attempt))', () {
      final client = GatewayClient(cfg, autoReconnect: false);
      const base = 300;
      const cap = 15000;
      for (var attempt = 0; attempt < 20; attempt++) {
        final ceiling = min(cap, base * pow(2, attempt));
        for (var i = 0; i < 200; i++) {
          final d = client.reconnectDelay(attempt).inMilliseconds;
          expect(d, inInclusiveRange(0, ceiling),
              reason: 'attempt=$attempt got ${d}ms outside [0,$ceiling)');
        }
      }
      client.dispose();
    });

    test('respects the 15s cap at high attempt counts', () {
      final client = GatewayClient(cfg, autoReconnect: false);
      for (var i = 0; i < 200; i++) {
        expect(client.reconnectDelay(30).inMilliseconds, lessThanOrEqualTo(15000));
      }
      client.dispose();
    });

    test('clamps negative attempts to 0', () {
      final client = GatewayClient(cfg, autoReconnect: false);
      final d = client.reconnectDelay(-5).inMilliseconds;
      expect(d, inInclusiveRange(0, 300));
      client.dispose();
    });

    test('is random, not constant (jitter actually varies)', () {
      final client = GatewayClient(cfg, autoReconnect: false);
      final seen = <int>{};
      for (var i = 0; i < 50; i++) {
        seen.add(client.reconnectDelay(4).inMilliseconds);
      }
      expect(seen.length, greaterThan(1), reason: 'jitter produced a single value');
      client.dispose();
    });
  });

  group('connection state model', () {
    test('reconnecting is a distinct state from open/error/closed', () {
      expect(GwConnectionState.values, contains(GwConnectionState.reconnecting));
      expect(GwConnectionState.reconnecting, isNot(GwConnectionState.error));
      expect(GwConnectionState.reconnecting, isNot(GwConnectionState.open));
      expect(GwConnectionState.reconnecting, isNot(GwConnectionState.closed));
    });

    test('autoReconnect flag is honored on the client', () {
      expect(GatewayClient(cfg, autoReconnect: true).autoReconnect, isTrue);
      expect(GatewayClient(cfg, autoReconnect: false).autoReconnect, isFalse);
    });
  });
}
