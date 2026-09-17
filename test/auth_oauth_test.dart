import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/native_oauth.dart';

void main() {
  group('PKCE', () {
    test('verifier is 43 chars base64url', () {
      final v = NativeOAuthService.generateVerifier(random: _deterministic());
      expect(v.length, 43);
      expect(v, isNot(contains('=')));
      expect(v, isNot(contains('+')));
      expect(v, isNot(contains('/')));
    });
    test('challenge is deterministic from verifier', () {
      final v = NativeOAuthService.generateVerifier(random: _deterministic());
      final c1 = NativeOAuthService.challengeFromVerifier(v);
      final c2 = NativeOAuthService.challengeFromVerifier(v);
      expect(c1, c2);
      expect(c1.length, 43);
    });
  });

  group('authorize URL', () {
    test('builds correct native authorize URL', () {
      final url = NativeOAuthService.buildAuthorizeUrl(
        baseUrl: 'http://gw.example.internal:9119',
        challenge: 'abc123',
        redirectUri: 'http://127.0.0.1:49152/callback',
        state: 'csrf_state',
      );
      expect(url.path, '/auth/native/authorize');
      expect(url.queryParameters['code_challenge'], 'abc123');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(url.queryParameters['redirect_uri'], 'http://127.0.0.1:49152/callback');
      expect(url.queryParameters['state'], 'csrf_state');
    });
    test('includes provider when specified', () {
      final url = NativeOAuthService.buildAuthorizeUrl(
        baseUrl: 'http://gw.example.com/hermes',
        challenge: 'c',
        redirectUri: 'http://127.0.0.1:1/cb',
        state: 's',
        provider: 'nous',
      );
      expect(url.path, '/hermes/auth/native/authorize');
      expect(url.queryParameters['provider'], 'nous');
    });
  });

  group('token URL builders', () {
    test('token URL strips trailing slash', () {
      expect(NativeOAuthService.buildTokenUrl('https://gw.example.com/').path,
          '/auth/native/token');
    });
    test('refresh URL preserves prefix', () {
      expect(NativeOAuthService.buildRefreshUrl('https://gw.example.com/hermes').path,
          '/hermes/auth/native/refresh');
    });
  });

  group('status detection', () {
    test('native_pkce in auth_flows => true', () {
      expect(NativeOAuthService.statusSupportsNativeFlow({'auth_flows': ['native_pkce']}), true);
    });
    test('missing auth_flows => false', () {
      expect(NativeOAuthService.statusSupportsNativeFlow({}), false);
    });
    test('empty auth_flows => false', () {
      expect(NativeOAuthService.statusSupportsNativeFlow({'auth_flows': []}), false);
    });
  });

  group('loopback callback parsing', () {
    test('parses valid callback', () {
      final code = NativeOAuthService.parseLoopbackCallback(
        callbackUri: Uri.parse('http://127.0.0.1:1234/cb?code=abc&state=s1'),
        expectedState: 's1',
      );
      expect(code, 'abc');
    });
    test('rejects state mismatch', () {
      expect(
        () => NativeOAuthService.parseLoopbackCallback(
          callbackUri: Uri.parse('http://127.0.0.1:1/cb?code=x&state=wrong'),
          expectedState: 'right',
        ),
        throwsA(isA<OAuthException>().having((e) => e.message, 'message', contains('state mismatch'))),
      );
    });
    test('rejects error response', () {
      expect(
        () => NativeOAuthService.parseLoopbackCallback(
          callbackUri: Uri.parse('http://127.0.0.1:1/cb?error=access_denied&error_description=User+cancelled'),
          expectedState: 's',
        ),
        throwsA(isA<OAuthException>().having((e) => e.message, 'message', contains('access_denied'))),
      );
    });
    test('rejects missing code', () {
      expect(
        () => NativeOAuthService.parseLoopbackCallback(
          callbackUri: Uri.parse('http://127.0.0.1:1/cb?state=s'),
          expectedState: 's',
        ),
        throwsA(isA<OAuthException>().having((e) => e.message, 'message', contains('missing authorization code'))),
      );
    });
  });

  group('token response parsing', () {
    test('parses valid response', () {
      final tokens = NativeOAuthService.parseTokenResponse({
        'access_token': 'at_123',
        'refresh_token': 'rt_456',
        'expires_at': 1700000000,
        'provider': 'nous',
        'user_id': 'u1',
      });
      expect(tokens.accessToken, 'at_123');
      expect(tokens.refreshToken, 'rt_456');
      expect(tokens.expiresAt, 1700000000);
    });
    test('rejects empty access_token', () {
      expect(
        () => NativeOAuthService.parseTokenResponse({'access_token': ''}),
        throwsA(isA<OAuthException>()),
      );
    });
    test('handles missing fields gracefully', () {
      final tokens = NativeOAuthService.parseTokenResponse({'access_token': 'x'});
      expect(tokens.accessToken, 'x');
      expect(tokens.refreshToken, '');
      expect(tokens.expiresAt, 0);
    });
  });

  group('token refresh check', () {
    test('unknown expiry needs refresh', () {
      expect(NativeOAuthService.tokenNeedsRefresh(
        const NativeTokenSet(accessToken: 'x'), nowSeconds: 1000), true);
    });
    test('not near expiry', () {
      expect(NativeOAuthService.tokenNeedsRefresh(
        const NativeTokenSet(accessToken: 'x', expiresAt: 2000), nowSeconds: 1000), false);
    });
    test('within skew window', () {
      expect(NativeOAuthService.tokenNeedsRefresh(
        const NativeTokenSet(accessToken: 'x', expiresAt: 1050), nowSeconds: 1000), true);
    });
  });

  group('NativeTokenSet JSON round-trip', () {
    test('serializes and deserializes', () {
      const t = NativeTokenSet(
        accessToken: 'at', refreshToken: 'rt', expiresAt: 123,
        provider: 'nous', userId: 'u1',
      );
      final json = t.toJson();
      final restored = NativeTokenSet.fromJson(json);
      expect(restored.accessToken, t.accessToken);
      expect(restored.refreshToken, t.refreshToken);
      expect(restored.expiresAt, t.expiresAt);
      expect(restored.provider, t.provider);
      expect(restored.userId, t.userId);
    });
  });
}

/// Deterministic RNG for reproducible tests.
class _deterministic implements Random {
  int _seed = 42;
  @override
  int nextInt(int max) {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return _seed % max;
  }
  @override
  bool nextBool() => nextInt(2) == 1;
  @override
  double nextDouble() => nextInt(1 << 32) / (1 << 32);
}
