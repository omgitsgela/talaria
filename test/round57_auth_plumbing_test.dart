import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/gateway/http_service.dart';
import 'package:talaria/src/gateway/native_oauth.dart';
import 'package:talaria/src/gateway/oauth_flow.dart';
import 'package:talaria/src/store/app_model.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 57 (pure suite): the auth rejection plumbing.
///
/// Field complaint: "when the app needs to reauth due to the server
/// restarting ... the OAuth screen doesn't let you go to the sign in page
/// all the time". One root cause was server-side truth being discarded
/// client-side: a 401 rejection looked like a network failure, so the backoff
/// loop re-presented the dead credential forever and nothing explained it.
///
/// These run WITHOUT the widget binding so real loopback sockets work (the
/// widget-test binding stubs all HttpClient traffic to status 400).
void main() {
  late FlutterSecureStoragePlatform originalStorage;
  setUp(() {
    originalStorage = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform({});
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = originalStorage;
    AppModel.clientFactoryForTest = null;
  });

  group('auth rejection is typed and explained', () {
    test('a 401 ticket mint carries the gateway\'s session_expired kind',
        () async {
      final config =
          GatewayConfig(url: 'http://localhost:9119', oauthToken: 'dead');
      final http0 = GatewayHttp(config, client: MockClient((req) async {
        return http.Response(
            jsonEncode({
              'error': 'session_expired',
              'reason': 'gateway restarted',
              'login_url': 'http://localhost:9119/login',
            }),
            401);
      }));
      await expectLater(
        http0.mintWsTicket(),
        throwsA(isA<GatewayAuthError>()
            .having((e) => e.sessionExpired, 'sessionExpired', true)
            .having((e) => e.reason, 'reason', 'gateway restarted')
            .having((e) => e.loginUrl, 'loginUrl',
                'http://localhost:9119/login')),
      );
      http0.close();
    });

    test('a bare 401 (no body) is still an auth rejection, just unexplained',
        () async {
      final config =
          GatewayConfig(url: 'http://localhost:9119', oauthToken: 'dead');
      final http0 = GatewayHttp(config,
          client: MockClient((req) async => http.Response('', 401)));
      await expectLater(
        http0.mintWsTicket(),
        throwsA(isA<GatewayAuthError>()
            .having((e) => e.sessionExpired, 'sessionExpired', false)),
      );
      http0.close();
    });

    test('the client parks in authRequired after a rejected dial — no backoff',
        () async {
      final gw = await _rejectGateway();
      final config = GatewayConfig(
          url: 'http://127.0.0.1:${gw.port}', oauthToken: 'dead');
      final client = GatewayClient(config);
      final states = <GwConnectionState>[];
      client.stateChanges.listen(states.add);

      await expectLater(client.connect(), throwsA(isA<GatewayAuthError>()));

      // The rejection parks the connection state: the UI branches on it.
      expect(client.state, GwConnectionState.authRequired);
      expect(client.needsReauth, isTrue);
      expect(client.authFailure!.sessionExpired, isTrue);
      // NO reconnecting state was ever entered: the retry loop is not armed.
      expect(states, isNot(contains(GwConnectionState.reconnecting)),
          reason: 'a rejected credential must not be re-presented forever');

      // A manual connect re-presents deliberately (the user pressed the
      // button), and it too parks without scheduling a retry.
      await expectLater(client.connect(), throwsA(isA<GatewayAuthError>()));
      expect(client.state, GwConnectionState.authRequired);
      await client.dispose();
      await gw.close(force: true);
    });

    test('the store invalidates a session-expired credential and explains it',
        () async {
      final gw = await _rejectGateway();
      final config = GatewayConfig(
          url: 'http://127.0.0.1:${gw.port}', oauthToken: 'dead');
      final runner = OAuthFlowRunner(store: OAuthTokenStore());
      await runner.store.save(config.baseUrl, NativeTokenSet(
          accessToken: 'dead',
          refreshToken: 'rt',
          expiresAt: 9999999999,
          provider: 'p',
          userId: 'u'));
      final store = ChatStore(config: config, oauthRunner: runner);

      await expectLater(store.connect(), throwsA(isA<GatewayAuthError>()));

      expect(store.needsReauth, isTrue);
      expect(store.connection, GwConnectionState.authRequired);
      expect(store.connectError, contains('ended your signed-in session'));
      expect(store.reauthExplanation, contains('gateway restart'));
      // The dead bearer is dropped from the live config...
      expect(config.oauthToken, isEmpty);
      // ...and the stored set is cleared with a recorded reason, so the
      // sign-in screen explains instead of pre-filling garbage. Allow the
      // fire-and-forget invalidation to land.
      for (var i = 0; i < 10; i++) {
        if (await runner.store.reauthNeededReason(config.baseUrl) != null) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(await runner.store.load(config.baseUrl), isNull);
      expect(await runner.store.reauthNeededReason(config.baseUrl),
          'session_expired');
      store.dispose();
      await gw.close(force: true);
    });

    test('a WS-layer 4401 close (loopback token gateway) also parks in '
        'authRequired instead of looping', () async {
      // Loopback token gateways never mint a ticket; they reject at the WS
      // gate with close code 4401 (verified: chat_ws.py closes 4401 on auth).
      final gw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      gw.listen((req) async {
        if (req.uri.path == '/api/ws') {
          final ws = await WebSocketTransformer.upgrade(req);
          await ws.close(4401, 'auth: bad credential');
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });
      final config =
          GatewayConfig(url: 'http://127.0.0.1:${gw.port}', token: 'dead-token');
      final client = GatewayClient(config);
      await client.connect().catchError((Object _) {});
      for (var i = 0;
          i < 10 && client.state != GwConnectionState.authRequired;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(client.state, GwConnectionState.authRequired,
          reason: '4401 must not fall into the backoff loop');
      expect(client.needsReauth, isTrue);
      await client.dispose();
      await gw.close(force: true);
    });

    test('an ordinary network failure still uses the reconnect backoff',
        () async {
      // The authRequired park must not swallow genuine transient failures:
      // nothing listens on this port, so the dial must schedule a retry.
      final config = GatewayConfig(url: 'http://127.0.0.1:1', token: 't');
      final client = GatewayClient(config);
      final states = <GwConnectionState>[];
      client.stateChanges.listen(states.add);
      await expectLater(client.connect(), throwsA(isA<GatewayError>()));
      // Give the state stream its delivery beats.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.state, GwConnectionState.reconnecting,
          reason: 'network failures keep the automatic recovery path');
      expect(states, contains(GwConnectionState.reconnecting),
          reason: 'network failures keep the automatic recovery path');
      expect(client.needsReauth, isFalse);
      await client.dispose();
    });
  });

  group('an explicit sign-in always reaches the browser', () {
    test('forceInteractive skips a locally-valid stored token', () async {
      final store = OAuthTokenStore();
      const base = 'http://gw.example.internal:9119';
      await store.save(base, NativeTokenSet(
          accessToken: 'looks-valid',
          refreshToken: 'rt',
          expiresAt: 9999999999,
          provider: 'p',
          userId: 'u'));
      var browserOpened = false;
      final runner = OAuthFlowRunner(
        store: store,
        httpClient:
            MockClient((req) async => throw Exception('no gateway in test')),
        timeout: const Duration(milliseconds: 300),
      );
      await expectLater(
        runner.resolveToken(
          GatewayConfig(url: base),
          openBrowser: (url) async => browserOpened = true,
          forceInteractive: true,
        ),
        throwsA(isA<OAuthException>()),
      );
      expect(browserOpened, isTrue,
          reason: 'a tap on Sign in must reach the sign-in page even when a '
              'stored token looks valid locally but was rejected server-side');
      // Starting a new session invalidates the old stored set first.
      expect(await store.load(base), isNull);
    });

    test('automatic resolveToken still uses the cached token (no browser)',
        () async {
      final store = OAuthTokenStore();
      const base = 'http://gw.example.internal:9119';
      await store.save(base, NativeTokenSet(
          accessToken: 'fresh',
          refreshToken: 'rt',
          expiresAt: 9999999999,
          provider: 'p',
          userId: 'u'));
      var browserOpened = false;
      final runner = OAuthFlowRunner(store: store);
      final set = await runner.resolveToken(
        GatewayConfig(url: base),
        openBrowser: (url) async => browserOpened = true,
      );
      expect(set.accessToken, 'fresh');
      expect(browserOpened, isFalse,
          reason: 'automatic recovery must not require a browser');
    });

    test('a transport failure on refresh falls back to interactive sign-in',
        () async {
      final store = OAuthTokenStore();
      const base = 'http://gw.example.internal:9119';
      await store.save(base, NativeTokenSet(
          accessToken: 'expired',
          refreshToken: 'rt',
          expiresAt: 1, // expired -> refresh attempted
          provider: 'p',
          userId: 'u'));
      var browserOpened = false;
      final runner = OAuthFlowRunner(
        store: store,
        // The refresh endpoint is unreachable (transport error).
        httpClient: MockClient(
            (req) async => throw http.ClientException('socket closed')),
        timeout: const Duration(milliseconds: 300),
      );
      await expectLater(
        runner.resolveToken(
          GatewayConfig(url: base),
          openBrowser: (url) async => browserOpened = true,
        ),
        throwsA(isA<OAuthException>()),
      );
      // The old behavior: the ClientException escaped resolveToken raw and
      // no sign-in was ever attempted. The new behavior falls through to
      // the interactive flow — which got reached (browser opened), even
      // though it then times out on its own terms in this test setup.
      expect(browserOpened, isTrue);
    });

    test('refresh 401 says what the server said instead of blaming a restart',
        () async {
      final gw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      gw.listen((req) async {
        if (req.uri.path == '/auth/native/refresh') {
          req.response.statusCode = 401;
          req.response.write(jsonEncode({'error': 'unauthenticated'}));
        }
        await req.response.close();
      });
      final store = OAuthTokenStore();
      final runner = OAuthFlowRunner(store: store);
      final base = 'http://127.0.0.1:${gw.port}';
      final result = await runner.refresh(base, NativeTokenSet(
          accessToken: 'at',
          refreshToken: 'rt',
          expiresAt: 1,
          provider: 'p',
          userId: 'u'));
      expect(result, isNull);
      // 'credential_rejected', not a false 'gateway_restart' claim.
      expect(await store.reauthNeededReason(base), 'credential_rejected');
      await gw.close(force: true);
    });

    test('refresh 401 session_expired is recorded as a session end', () async {
      final gw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      gw.listen((req) async {
        if (req.uri.path == '/auth/native/refresh') {
          req.response.statusCode = 401;
          req.response.write(jsonEncode({'error': 'session_expired'}));
        }
        await req.response.close();
      });
      final store = OAuthTokenStore();
      final runner = OAuthFlowRunner(store: store);
      final base = 'http://127.0.0.1:${gw.port}';
      final result = await runner.refresh(base, NativeTokenSet(
          accessToken: 'at',
          refreshToken: 'rt',
          expiresAt: 1,
          provider: 'p',
          userId: 'u'));
      expect(result, isNull);
      expect(await store.reauthNeededReason(base), 'session_expired');
      await gw.close(force: true);
    });

    test('cancelling an in-flight sign-in releases the waiter', () async {
      final runner = OAuthFlowRunner(
        store: OAuthTokenStore(),
        httpClient:
            MockClient((req) async => throw Exception('no gateway in test')),
        timeout: const Duration(minutes: 2),
      );
      final signIn = runner.signIn(
        GatewayConfig(url: 'http://127.0.0.1:9'),
        // The browser tab opens fine (launch resolves) but never calls back
        // (the abandoned flow). signIn then sits in the callback await.
        openBrowser: (_) async {},
      );
      // Give signIn time to reach the callback await.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await runner.cancelActiveSignIn();
      await expectLater(
        signIn,
        throwsA(isA<OAuthException>()
            .having((e) => e.message, 'message', contains('cancelled'))),
      );
      // A second cancel is harmless (no flow in flight).
      await runner.cancelActiveSignIn();
    });
  });

  group('a replaced store stops dialing', () {
    test('AppModel disposes the store it replaces', () async {
      AppModel.clientFactoryForTest = (cfg) => _AuthRejectingClient(cfg);
      final model = AppModel(saved: GatewayConfig(url: 'https://gw.example.com:9119'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final old = model.store!;
      // The startup dial failed with an auth rejection. A NEW connect
      // (the public replacement path the connect screen uses after the
      // watchdog re-arms) must dispose the failed store first, or its
      // client keeps retry state that could keep dialing the old
      // credential from the background.
      await model.connect(GatewayConfig(url: 'https://other.example.com:9119'));
      expect(model.store, isNot(same(old)));
      // The replaced store is disposed: any dial attempt trips the
      // disposed-state guard (FlutterError) instead of reaching the wire.
      await expectLater(old.connect(), throwsA(isA<FlutterError>()));
      model.dispose();
    });
  });
}

/// Connect always fails like the gateway's auth gate rejecting a bearer.
class _AuthRejectingClient extends GatewayClient {
  _AuthRejectingClient(super.config);
  @override
  Future<void> connect({bool isReconnect = false}) async {
    throw GatewayAuthError('Gateway rejected the stored sign-in (HTTP 401)',
        sessionExpired: true, reason: 'gateway restarted');
  }

  @override
  Stream<GwConnectionState> get stateChanges => const Stream.empty();

  @override
  Stream<GatewayEvent> get events => const Stream.empty();

  @override
  Stream<ServerRequest> get serverRequests => const Stream.empty();

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    throw GatewayError('gateway not connected');
  }
}

Future<HttpServer> _rejectGateway() async {
  final gw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  gw.listen((req) async {
    if (req.uri.path == '/api/auth/ws-ticket') {
      req.response.statusCode = 401;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'error': 'session_expired',
        'reason': 'gateway restarted',
      }));
    } else if (req.uri.path == '/api/status') {
      req.response
          .write(jsonEncode({'ok': true, 'auth_flows': ['native_pkce']}));
    } else if (req.uri.path == '/api/health') {
      req.response.write(jsonEncode({'ok': true}));
    } else {
      req.response.statusCode = 404;
    }
    await req.response.close();
  });
  return gw;
}
