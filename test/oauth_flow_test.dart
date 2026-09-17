import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/gateway/native_oauth.dart';
import 'package:talaria/src/gateway/oauth_flow.dart';

void main() {
  late FlutterSecureStoragePlatform original;
  setUp(() {
    original = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform({});
  });
  tearDown(() => FlutterSecureStoragePlatform.instance = original);

  group('OAuthTokenStore', () {
    test('saves and restores a token set per gateway url', () async {
      final store = OAuthTokenStore();
      final base = 'https://gw.example.internal:9119';
      final set = NativeTokenSet(
          accessToken: 'at-1',
          refreshToken: 'rt-1',
          expiresAt: 9999999999,
          provider: 'portal',
          userId: 'u1');
      await store.save(base, set);
      final loaded = await store.load(base);
      expect(loaded, isNotNull);
      expect(loaded!.accessToken, 'at-1');
      expect(loaded.refreshToken, 'rt-1');
      // A different gateway URL must not leak the entry.
      expect(await store.load('https://other.example:9119'), isNull);
      await store.clear(base);
      expect(await store.load(base), isNull);
    });

    test('corrupt entry is dropped, not thrown', () async {
      final fake = FlutterSecureStoragePlatform.instance
          as TestFlutterSecureStoragePlatform;
      final base = 'https://gw.example.internal:9119';
      // _keyFor -> scheme://host:port/path
      fake.data['talaria.oauth.https://gw.example.internal:9119'] = 'not-json';
      final store = OAuthTokenStore();
      expect(await store.load(base), isNull);
    });

    test('different paths on same host use different keys', () async {
      final store = OAuthTokenStore();
      final base1 = 'https://gw.example.internal:9119/gateway-a';
      final base2 = 'https://gw.example.internal:9119/gateway-b';
      final set1 = NativeTokenSet(accessToken: 'at-1', refreshToken: 'rt-1', expiresAt: 9999999999, provider: 'p', userId: 'u1');
      final set2 = NativeTokenSet(accessToken: 'at-2', refreshToken: 'rt-2', expiresAt: 9999999999, provider: 'p', userId: 'u2');
      await store.save(base1, set1);
      await store.save(base2, set2);
      final loaded1 = await store.load(base1);
      final loaded2 = await store.load(base2);
      expect(loaded1!.accessToken, 'at-1');
      expect(loaded2!.accessToken, 'at-2');
      expect(await store.load('https://gw.example.internal:9119'), isNull);
    });
  });

  group('OAuthFlowRunner (loopback integration)', () {
    test('full PKCE sign-in: browser redirect -> code redeem -> stored',
        () async {
      // Fake gateway implementing the native OAuth endpoints.
      final gw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var authorizeHits = 0;
      var tokenHits = 0;
      gw.listen((req) async {
        final u = req.uri;
        if (u.path == '/api/status') {
          req.response
              .write(jsonEncode({'ok': true, 'auth_flows': ['native_pkce']}));
        } else if (u.path == '/auth/native/authorize') {
          authorizeHits++;
          final state = u.queryParameters['state'];
          final redirect = u.queryParameters['redirect_uri'];
          // The "browser" (openBrowser) will GET this URL; the fake gateway
          // redirects it to the app's loopback callback with a code.
          req.response.statusCode = 302;
          req.response.headers.set('location',
              '$redirect?code=fake-code-123&state=$state');
        } else if (u.path == '/auth/native/token') {
          tokenHits++;
          // Check that headers are present
          if (req.headers.value('X-Proxy-Id') != 'test-proxy' || req.headers.value('X-Proxy-Secret') != 'secret123') {
            req.response.statusCode = 400; // Fail if headers missing
          }
          final raw = await utf8.decodeStream(req);
          final body = jsonDecode(raw) as Map<String, dynamic>;
          if ((body['code'] as String?) != 'fake-code-123') {
            req.response.statusCode = 400;
          }
          if ((body['code_verifier'] as String?)?.isEmpty == true) {
            req.response.statusCode = 400;
          }
          req.response.write(jsonEncode({
            'access_token': 'at-abc',
            'refresh_token': 'rt-def',
            'expires_at': 9999999999,
            'provider': 'portal',
            'user_id': 'u42'
          }));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final headers = {'X-Proxy-Id': 'test-proxy', 'X-Proxy-Secret': 'secret123'};
      final config = GatewayConfig(url: 'http://127.0.0.1:${gw.port}', headers: headers);
      final browserClient = http.Client();
      final runner = OAuthFlowRunner(
          store: OAuthTokenStore(), httpClient: browserClient);

      expect(await runner.supportsNativeFlow(config), isTrue);

      final tokens = await runner.signIn(
        config,
        openBrowser: (url) async {
          // Simulate the system browser: GET the authorize URL and follow the
          // gateway's 302 to the loopback callback (default behavior).
          await browserClient
              .get(url)
              .timeout(const Duration(seconds: 10));
        },
      );

      expect(tokens.accessToken, 'at-abc');
      expect(tokens.refreshToken, 'rt-def');
      expect(tokens.userId, 'u42');
      expect(authorizeHits, 1);
      expect(tokenHits, 1);

      // The token set was persisted to secure storage under the gateway url.
      final stored = await runner.store.load(config.baseUrl);
      expect(stored, isNotNull);
      expect(stored!.accessToken, 'at-abc');

      browserClient.close();
      await gw.close(force: true);
    });

    test('CSRF state mismatch is rejected (forged callback)', () async {
      final gw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      gw.listen((req) async {
        final u = req.uri;
        if (u.path == '/api/status') {
          req.response.write(jsonEncode(
              {'ok': true, 'auth_flows': ['native_pkce']}));
        } else if (u.path == '/auth/native/authorize') {
          req.response.statusCode = 302;
          // Attacker-controlled redirect with the WRONG state.
          req.response.headers.set('location',
              '${u.queryParameters['redirect_uri']}?code=evil&state=forged');
        }
        await req.response.close();
      });

      final config = GatewayConfig(url: 'http://127.0.0.1:${gw.port}');
      final browserClient = http.Client();
      final runner = OAuthFlowRunner(
          store: OAuthTokenStore(), httpClient: browserClient);

      await expectLater(
        runner.signIn(
          config,
          openBrowser: (url) async {
            // The attacker's browser follows the forged redirect.
            await browserClient
                .get(url)
                .timeout(const Duration(seconds: 10));
          },
        ),
        throwsA(isA<OAuthException>()),
      );

      browserClient.close();
      await gw.close(force: true);
    });

    test('refresh sends proxy headers', () async {
      final gw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var refreshHits = 0;
      gw.listen((req) async {
        final u = req.uri;
        if (u.path == '/auth/native/refresh') {
          refreshHits++;
          // Check headers
          expect(req.headers.value('X-Proxy-Id'), 'test-proxy');
          expect(req.headers.value('content-type'), contains('application/json'));
          req.response.write(jsonEncode({
            'access_token': 'new-at',
            'refresh_token': 'new-rt',
            'expires_at': 9999999999,
            'provider': 'p',
            'user_id': 'u1'
          }));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final headers = {'X-Proxy-Id': 'test-proxy'};
      final config = GatewayConfig(url: 'http://127.0.0.1:${gw.port}', headers: headers);
      final runner = OAuthFlowRunner(store: OAuthTokenStore());
      final set = NativeTokenSet(accessToken: 'at', refreshToken: 'rt', expiresAt: 0, provider: 'p', userId: 'u1');
      
      final refreshed = await runner.refresh(config.baseUrl, set, headers: config.headers);
      
      expect(refreshHits, 1);
      expect(refreshed!.accessToken, 'new-at');
      
      await gw.close(force: true);
    });
  });
}
