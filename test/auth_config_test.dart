import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/config.dart';

void main() {
  test('proxy headers survive connection screen build', () {
    var c = GatewayConfig(url: 'http://x', headers: {'cf-access-client-id': 'cid', 'cf-access-client-secret': 'csec'});
    c = c.copyWith(oauthToken: 'tok');
    expect(c.headers['cf-access-client-id'], 'cid');
    expect(c.headers['cf-access-client-secret'], 'csec');
    expect(c.authHeaders['cf-access-client-id'], 'cid');
    expect(c.authHeaders['Authorization'], 'Bearer tok');
  });
  test('bearer-only config produces Authorization header', () {
    final c = GatewayConfig(url: 'http://x', bearerToken: 'bt');
    expect(c.authHeaders['Authorization'], 'Bearer bt');
    expect(c.usesToken, false);
    expect(c.usesOAuth, false);
  });
  test('token config uses X-Hermes-Session-Token', () {
    final c = GatewayConfig(url: 'http://x', token: 't1');
    expect(c.authHeaders['X-Hermes-Session-Token'], 't1');
    expect(c.wsUrl(), contains('?token=t1'));
  });
  test('ticket overrides token in wsUrl', () {
    final c = GatewayConfig(url: 'http://x', token: 't1');
    expect(c.wsUrl(ticket: 'tk1'), contains('?ticket=tk1'));
    expect(c.wsUrl(ticket: 'tk1'), isNot(contains('token=')));
  });
}
