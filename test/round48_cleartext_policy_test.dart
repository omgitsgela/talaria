import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/gateway/host_policy.dart';

/// Round 48: cleartext, scoped by host.
///
/// Google's published guidance is not to enable cleartext application-wide but
/// to permit it only where it is needed. Talaria is a client for a gateway the
/// user chooses, and a self-hosted gateway on a LAN is plainly `http://`, so a
/// blanket refusal is unusable and a blanket allowance is what the guidance
/// warns about. The rule is therefore: plain http is acceptable to a private,
/// loopback or link-local destination, and required to be https anywhere else,
/// because that is the traffic that leaves the network.
void main() {
  group('a destination where plain http is fine', () {
    const allowed = <String>[
      'localhost',
      'app.localhost',
      '127.0.0.1',
      '127.1.2.3',
      '10.0.0.5',
      '10.0.2.2',
      '172.16.0.1',
      '172.31.255.254',
      '192.168.0.142',
      '192.168.1.1',
      '169.254.10.10',
      '::1',
      'fe80::1',
      'fd00::1234',
      // A bare hostname cannot resolve on the public internet: this is how a
      // self-hosted box is normally reached.
      'autumn',
      'hermes',
      'hermes.local',
      'gw.lan',
      'nas.internal',
      'box.home.arpa',
      // An IPv4-mapped IPv6 private address is still private.
      '::ffff:192.168.1.5',
      // Zone index on a link-local address.
      'fe80::1%wlan0',
      '[::1]',
    ];
    for (final h in allowed) {
      test('allows $h', () => expect(isPrivateGatewayHost(h), isTrue));
    }
  });

  group('a destination that must be https', () {
    const refused = <String>[
      '8.8.8.8',
      '1.1.1.1',
      '172.32.0.1', // just outside 172.16/12
      '192.169.0.1',
      '11.0.0.1',
      '169.255.0.1',
      'gw.example.com',
      'myvps.net',
      'talaria.example.org',
      '2606:4700::1111',
      // Mapped public addresses must not smuggle past the IPv4 checks.
      '::ffff:8.8.8.8',
      '',
      '   ',
    ];
    for (final h in refused) {
      test('refuses $h', () => expect(isPrivateGatewayHost(h), isFalse));
    }
  });

  test('an address with no scheme gets the scheme its host deserves', () {
    // The old behaviour prefixed http:// unconditionally, which is how a public
    // gateway ended up with its token on the wire in the clear.
    expect(GatewayConfig(url: 'autumn:9119').baseUrl, 'http://autumn:9119');
    expect(GatewayConfig(url: '192.168.0.142:9119').baseUrl,
        'http://192.168.0.142:9119');
    expect(GatewayConfig(url: 'gw.example.com').baseUrl,
        'https://gw.example.com');
    // An explicit scheme is always respected.
    expect(GatewayConfig(url: 'https://192.168.0.142').baseUrl,
        'https://192.168.0.142');
    expect(GatewayConfig(url: 'http://gw.example.com').cleartextRefusal,
        isNotNull,
        reason: 'an explicit cleartext public URL is refused, not silently used');
  });

  test('the refusal names the host and says what to do', () {
    final why = cleartextRefusalFor('http://gw.example.com:9119');
    expect(why, isNotNull);
    expect(why!, contains('gw.example.com'));
    expect(why, contains('https'));

    expect(cleartextRefusalFor('http://192.168.0.142:9119'), isNull);
    expect(cleartextRefusalFor('https://gw.example.com'), isNull);
    expect(cleartextRefusalFor('autumn:9119'), isNull);
    expect(cleartextRefusalFor(''), isNull);
  });

  test('connecting to a public http gateway fails before any socket is opened',
      () async {
    final client = GatewayClient(
        GatewayConfig(url: 'http://gw.example.com:9119'));
    addTearDown(client.dispose);
    await expectLater(
        () => client.connect(),
        throwsA(isA<GatewayError>().having(
            (e) => e.message, 'message', contains('gw.example.com'))));
  });

  test('a private http gateway is not refused for being cleartext', () async {
    final cfg = GatewayConfig(url: 'http://127.0.0.1:1');
    expect(cfg.cleartextRefusal, isNull);
  });
}
