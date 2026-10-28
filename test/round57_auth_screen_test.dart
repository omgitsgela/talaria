import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/gateway/http_service.dart';
import 'package:talaria/src/gateway/oauth_flow.dart';
import 'package:talaria/src/screens/connection_screen.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/app_model.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 57 (widget suite): sign-in reachability and failure visibility.
///
/// Field complaint: "the OAuth screen doesn't let you go to the sign in page
/// all the time, and some quality of life features might be missing."
///
/// The widget-test binding stubs ALL HttpClient traffic to status 400, so
/// every fake here is a pure seam (no real sockets): the auth-flows probe via
/// httpFactoryForTest, and dial failures via AppModel.clientFactoryForTest.
void main() {
  setUp(() {
    ConnectionScreen.httpFactoryForTest = null;
    AppModel.clientFactoryForTest = null;
    ConnectionScreen.oauthStoreForTest = null;
    // Default seam: every model-owned dial fails like an unreachable
    // gateway. Without it, a saved config's startup dial opens a real
    // WebSocket attempt whose 15s ready-timeout lingers as a pending
    // fake-clock timer and fails the test at teardown.
    AppModel.clientFactoryForTest = (cfg) => _PlainFailClient(cfg);
  });
  tearDown(() {
    ConnectionScreen.httpFactoryForTest = null;
    AppModel.clientFactoryForTest = null;
    ConnectionScreen.oauthStoreForTest = null;
  });

  group('the sign-in page is reachable', () {
    testWidgets('the OAuth tab always offers Sign in with Hermes, even when '
        'the gateway probe failed', (tester) async {
      _phoneSurface(tester);
      // The probe cannot answer (offline / gated / WAF). The OLD code hid
      // the button behind shouldOfferNativeSignIn(false, false): the probe
      // needs a working credential, which is exactly what is missing at
      // first sign-in or after a restart.
      ConnectionScreen.httpFactoryForTest = (cfg) =>
          GatewayHttp(cfg, client: MockClient((req) async {
            throw http.ClientException('connection refused');
          }));
      AppModel.clientFactoryForTest = (cfg) => _PlainFailClient(cfg);
      final model = AppModel(
          saved: GatewayConfig(url: 'https://gw.example.com:9119'),
          oauthRunner: _quietRunner());
      await tester
          .pumpWidget(MaterialApp(home: ConnectionScreen(model: model)));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.text('OAuth bearer'));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('Sign in with Hermes'), findsOneWidget);
      model.dispose();
    });

    testWidgets('a failed Test connection does not erase a known sign-in '
        'option', (tester) async {
      _phoneSurface(tester);
      var statusFails = false;
      ConnectionScreen.httpFactoryForTest = (cfg) => GatewayHttp(cfg,
          client: MockClient((req) async {
            if (req.url.path == '/api/status') {
              return http.Response(
                  jsonEncode({'ok': true, 'auth_flows': ['native_pkce']}), 200);
            }
            if (req.url.path == '/api/health') {
              // Fail the probe at the health step: a healthy gateway would
              // make testConnection spin up its own WebSocket dial, whose
              // timeout lives inside GatewayHttp (no seam) and lingers as a
              // pending fake-clock timer. Health failing short-circuits it.
              if (statusFails) return http.Response('', 503);
              return http.Response(jsonEncode({'ok': true}), 200);
            }
            return http.Response('', 404);
          }));
      final model = AppModel(
          saved: GatewayConfig(url: 'https://gw.example.com:9119'),
          oauthRunner: _quietRunner());
      await tester
          .pumpWidget(MaterialApp(home: ConnectionScreen(model: model)));
      await tester.pump(const Duration(milliseconds: 60));
      // Discovery confirmed native_pkce. The tab may already be on OAuth
      // (discovery auto-selects it for a gateway with no stored token);
      // selecting the segment again is a no-op either way.
      await tester.tap(find.text('OAuth bearer'));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('Sign in with Hermes'), findsOneWidget);
      // Now the gateway starts failing and the user presses Test connection.
      statusFails = true;
      await tester.tap(find.text('Test connection'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Sign in with Hermes'), findsOneWidget,
          reason: 'a failed probe says nothing about auth flows and must '
              'not remove the option discovery already confirmed');
      model.dispose();
    });

    testWidgets('discovery auto-selects the sign-in tab for an OAuth-capable '
        'gateway with no stored token', (tester) async {
      _phoneSurface(tester);
      ConnectionScreen.httpFactoryForTest = (cfg) => GatewayHttp(cfg,
          client: MockClient((req) async {
            if (req.url.path == '/api/status') {
              return http.Response(
                  jsonEncode({'ok': true, 'auth_flows': ['native_pkce']}), 200);
            }
            return http.Response('', 404);
          }));
      AppModel.clientFactoryForTest = (cfg) => _PlainFailClient(cfg);
      final model = AppModel(
          saved: GatewayConfig(url: 'https://gw.example.com:9119'),
          oauthRunner: _quietRunner());
      await tester
          .pumpWidget(MaterialApp(home: ConnectionScreen(model: model)));
      await tester.pump(const Duration(milliseconds: 60));
      // The reported first-time-auth complaint: the screen opens on a token
      // field the user has no token for. Discovery now moves them to where
      // the sign-in button is, without any press.
      expect(find.text('Sign in with Hermes'), findsOneWidget);
      model.dispose();
    });

    testWidgets('the Token tab offers a route into the sign-in page, with a '
        'cancel affordance', (tester) async {
      _phoneSurface(tester);
      // No saved config: the screen opens on the Token tab. A first-time
      // OAuth user used to see only a token field they had no token for.
      ConnectionScreen.httpFactoryForTest = (cfg) =>
          GatewayHttp(cfg, client: MockClient((req) async {
            throw http.ClientException('no gateway');
          }));
      final model = AppModel(
          openBrowser: (_) => Completer<void>().future,
          oauthRunner: _quietRunner(timeout: const Duration(minutes: 2)));
      await tester
          .pumpWidget(MaterialApp(home: ConnectionScreen(model: model)));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byKey(const ValueKey('token_tab_signin_link')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('token_tab_signin_link')));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byKey(const ValueKey('oauth_cancel_button')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('oauth_cancel_button')));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('Or sign in with Hermes'), findsOneWidget);
      expect(find.byKey(const ValueKey('token_tab_oauth_error')), findsOneWidget);
      expect(find.textContaining('Sign-in cancelled'), findsOneWidget);
      model.dispose();
    });

    testWidgets('an abandoned browser flow can be cancelled and the form '
        're-arms immediately', (tester) async {
      _phoneSurface(tester);
      ConnectionScreen.httpFactoryForTest = (cfg) => GatewayHttp(cfg,
          client: MockClient((req) async {
            if (req.url.path == '/api/status') {
              return http.Response(
                  jsonEncode({'ok': true, 'auth_flows': ['native_pkce']}), 200);
            }
            return http.Response('', 404);
          }));
      // A browser that opens but never calls back (the user closed the tab).
      AppModel.clientFactoryForTest = (cfg) => _PlainFailClient(cfg);
      final model = AppModel(
        saved: GatewayConfig(url: 'https://gw.example.com:9119'),
        openBrowser: (_) => Completer<void>().future,
        oauthRunner: _quietRunner(timeout: const Duration(minutes: 2)),
      );
      await tester
          .pumpWidget(MaterialApp(home: ConnectionScreen(model: model)));
      await tester.pump(const Duration(milliseconds: 60));
      // Discovery switched to the sign-in tab automatically (no stored token).
      expect(find.text('Sign in with Hermes'), findsOneWidget);

      await tester.tap(find.text('Sign in with Hermes'));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byKey(const ValueKey('oauth_cancel_button')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('oauth_cancel_button')));
      await tester.pump(const Duration(milliseconds: 60));

      // The buttons come back at once instead of waiting out the two-minute
      // callback timeout, with an honest message.
      expect(find.text('Sign in with Hermes'), findsOneWidget);
      final signBtn = tester.widget<FilledButton>(find.ancestor(
          of: find.text('Sign in with Hermes'),
          matching: find.byType(FilledButton)));
      expect(signBtn.onPressed, isNotNull);
      expect(find.textContaining('Sign-in cancelled'), findsWidgets);
      expect(find.byKey(const ValueKey('oauth_cancel_button')), findsNothing);
      model.dispose();
    });
  });

  group('connect failures are visible and explained', () {
    testWidgets('a rejected credential shows the rejection reason and moves '
        'the screen to the sign-in action', (tester) async {
      _phoneSurface(tester);
      ConnectionScreen.httpFactoryForTest = (cfg) =>
          GatewayHttp(cfg, client: MockClient((req) async {
            throw http.ClientException('unused');
          }));
      // The startup dial of the saved config is rejected by the gateway
      // exactly like a post-restart session_expired would be.
      AppModel.clientFactoryForTest = (cfg) =>
          _RejectingClient(cfg, sessionExpired: true);
      final model = AppModel(
          saved: GatewayConfig(
              url: 'https://gw.example.com:9119', oauthToken: 'dead'),
          oauthRunner: _quietRunner());
      await tester.pump(const Duration(milliseconds: 20));
      await tester
          .pumpWidget(MaterialApp(home: ConnectionScreen(model: model)));
      await tester.pump(const Duration(milliseconds: 60));

      expect(model.phase, AppPhase.noConnection);
      expect(model.needsReauth, isTrue);
      expect(find.byKey(const ValueKey('connect_error_banner')), findsOneWidget);
      expect(find.textContaining('ended your signed-in session'), findsOneWidget,
          reason: 'the rejection reason must reach the user, not just the log');
      // The screen moved itself to the OAuth tab where Sign in waits.
      expect(find.text('Sign in with Hermes'), findsOneWidget);
      model.dispose();
    });

    testWidgets('an ordinary failed connect re-arms the buttons and shows '
        'the failure', (tester) async {
      _phoneSurface(tester);
      ConnectionScreen.httpFactoryForTest = (cfg) =>
          GatewayHttp(cfg, client: MockClient((req) async {
            throw http.ClientException('unused');
          }));
      AppModel.clientFactoryForTest = (cfg) => _RejectingClient(cfg);
      final model = AppModel(oauthRunner: _quietRunner());
      await tester
          .pumpWidget(MaterialApp(home: ConnectionScreen(model: model)));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.enterText(find.byType(TextFormField).first,
          'https://gw.example.com:9119');
      await tester.tap(find.text('Connect'));
      await tester.pump(const Duration(milliseconds: 60));

      final btn = tester.widget<FilledButton>(find.ancestor(
          of: find.text('Connect'), matching: find.byType(FilledButton)));
      expect(btn.onPressed, isNotNull,
          reason: 'the form must never sit in Connecting forever');
      expect(find.byKey(const ValueKey('connect_error_banner')), findsOneWidget);
      expect(model.phase, AppPhase.noConnection);
      model.dispose();
    });
  });

  group('the Home connection sheet handles a rejected credential', () {
    testWidgets('the sheet offers Sign in again (not Reconnect) when the '
        'gateway rejected the credential', (tester) async {
      _phoneSurface(tester);
      final config = GatewayConfig(
          url: 'https://gw.example.com:9119', oauthToken: 'dead');
      final store = ChatStore(config: config, client: _RejectingClient(config,
          sessionExpired: true));
      await tester.pumpWidget(
          MaterialApp(home: HomeScreen(storeOverride: store)));
      await tester.pump(const Duration(milliseconds: 60));

      await store.connect().catchError((Object _) {});
      await tester.pump(const Duration(milliseconds: 60));

      // Open the connection sheet via the status pill (the established
      // pattern in launch_background_grouping_test taps the pill text).
      expect(find.text('offline'), findsOneWidget);
      await tester.tap(find.text('offline'));
      await tester.pumpAndSettle();

      expect(find.text('Sign-in required'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('home_reauth_explanation')), findsOneWidget);
      expect(find.text('Reconnect'), findsNothing,
          reason: 'Reconnect would re-present the dead credential forever');
      expect(find.byKey(const ValueKey('home_sign_in_again')), findsOneWidget);
      store.dispose();
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────

void _phoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// A runner whose HTTP side can never be reached, so sign-in attempts fail
/// fast and deterministically inside the widget clock.
OAuthFlowRunner _quietRunner({Duration timeout = const Duration(seconds: 5)}) =>
    OAuthFlowRunner(
      store: OAuthTokenStore(),
      httpClient: MockClient((req) async {
        throw http.ClientException('no gateway in widget test');
      }),
      timeout: timeout,
    );

/// A client whose dial fails like an unreachable gateway (not an auth gate).
class _PlainFailClient extends GatewayClient {
  _PlainFailClient(super.config);

  @override
  Future<void> connect({bool isReconnect = false}) async {
    throw GatewayError('WebSocket connection failed: network unreachable');
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

  @override
  void close() {}
}

/// A client whose dial always fails like the gateway's auth gate.
class _RejectingClient extends GatewayClient {
  _RejectingClient(super.config, {this.sessionExpired = false});
  final bool sessionExpired;

  @override
  Future<void> connect({bool isReconnect = false}) async {
    throw GatewayAuthError(
        'Gateway rejected the stored sign-in (HTTP 401)',
        sessionExpired: sessionExpired,
        reason: 'gateway restarted');
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

  @override
  void close() {}
}
