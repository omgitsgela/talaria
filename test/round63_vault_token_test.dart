import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:talaria/src/screens/connection_screen.dart';
import 'package:talaria/src/store/app_model.dart';

/// Round 63 (#39 follow-up): the vault token must reach the form, and the
/// sign-in keep-alive must fire when a FAILED store is on screen.
///
/// Field evidence: the gateway logged native_token_success (code exchanged,
/// token saved to secure storage), yet the connect screen still showed an
/// EMPTY Bearer field and tapping Connect dialed bare - the gate answered
/// 403 at the WS upgrade with no auth-log line at all, because
/// mintWsTicket() returns null for an empty oauthToken. Separately, the
/// keep-alive condition `_store == null` skipped protection in exactly the
/// reauth state (a store kept for error surfacing never started the
/// service because its socket never connected) - and the app was reaped
/// mid-browser AGAIN after a SUCCESSFUL exchange.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FlutterSecureStoragePlatform original;
  setUp(() {
    original = FlutterSecureStoragePlatform.instance;
    ConnectionScreen.httpFactoryForTest = null;
    AppModel.clientFactoryForTest = null;
    ConnectionScreen.oauthStoreForTest = null;
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = original;
    ConnectionScreen.httpFactoryForTest = null;
    AppModel.clientFactoryForTest = null;
    ConnectionScreen.oauthStoreForTest = null;
  });

  group('the Bearer field hydrates from the token vault', () {
    testWidgets('a stored token fills the empty field after a sign-in whose '
        'follow-up dial never happened', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      // Vault holds a LIVE token for this gateway; the saved connection
      // record carries NO oauthToken (the exchange completed but the app
      // died before connecting, and the record predates the token).
      FlutterSecureStoragePlatform.instance =
          TestFlutterSecureStoragePlatform({
        'talaria.oauth.https://gw.example.com:9119': jsonEncode({
          'accessToken': 'vault-at-1',
          'refreshToken': 'rt-1',
          'expiresAt': 9999999999,
          'provider': 'basic',
          'userId': 'hermes',
        }),
      });
      ConnectionScreen.httpFactoryForTest = (cfg) => GatewayHttp(cfg,
          client: MockClient((req) async {
            if (req.url.path == '/api/status') {
              return http.Response(
                  jsonEncode({'ok': true, 'auth_flows': ['native_pkce']}),
                  200);
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
      await tester.pump(const Duration(milliseconds: 900)); // discovery + vault
      await tester.tap(find.text('OAuth bearer'));
      await tester.pump(const Duration(milliseconds: 60));
      final bearer = tester.widget<TextFormField>(
          find.ancestor(
              of: find.text('Bearer token'),
              matching: find.byType(TextFormField)));
      expect(bearer.controller?.text, 'vault-at-1',
          reason: 'the vault token is the credential Connect must dial with; '
              'an empty field dialed bare and got a bare 403');
      model.dispose();
    });

    testWidgets('the field is NOT pre-filled when the session ended',
        (tester) async {
      // The reauth marker is the recorded proof the vault token is DEAD.
      // Hydration must not resurrect it: _loadStoredToken runs first, then
      // _loadReauthState clears - order is pinned in initState.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      FlutterSecureStoragePlatform.instance =
          TestFlutterSecureStoragePlatform({
        'talaria.oauth.https://gw.example.com:9119': jsonEncode({
          'accessToken': 'dead-at-1',
          'refreshToken': '',
          'expiresAt': 9999999999,
          'provider': 'basic',
          'userId': 'hermes',
        }),
        'talaria.reauth.talaria.oauth.https://gw.example.com:9119':
            'session_expired',
      });
      ConnectionScreen.httpFactoryForTest = (cfg) => GatewayHttp(cfg,
          client: MockClient((req) async {
            if (req.url.path == '/api/status') {
              return http.Response(
                  jsonEncode({'ok': true, 'auth_flows': ['native_pkce']}),
                  200);
            }
            return http.Response('', 404);
          }));
      AppModel.clientFactoryForTest = (cfg) => _PlainFailClient(cfg);
      final model = AppModel(
          saved: GatewayConfig(
              url: 'https://gw.example.com:9119', oauthToken: 'dead-at-1'),
          oauthRunner: _quietRunner());
      await tester
          .pumpWidget(MaterialApp(home: ConnectionScreen(model: model)));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.tap(find.text('OAuth bearer'));
      await tester.pump(const Duration(milliseconds: 60));
      final bearer = tester.widget<TextFormField>(
          find.ancestor(
              of: find.text('Bearer token'),
              matching: find.byType(TextFormField)));
      expect(bearer.controller?.text ?? '', isEmpty,
          reason: 'a session the gateway ENDED must never be presented as a '
              'usable token, even when it still sits in the vault');
      model.dispose();
    });
  });

  group('sign-in keep-alive covers the reauth state (phase noConnection, '
      'failed store on screen)', () {
    test('start/stop wrap the interactive flow even when a dead store '
        'exists', () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('talaria/foreground'), (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('talaria/foreground'), null));
      FlutterSecureStoragePlatform.instance =
          TestFlutterSecureStoragePlatform({});
      AppModel.clientFactoryForTest = (cfg) => _PlainFailClient(cfg);
      final model = AppModel(
          saved: GatewayConfig(url: 'https://gw.example.com:9119'),
          oauthRunner: _quietRunner());
      // Wait for the startup dial to fail: now the state the user is
      // ACTUALLY in when reauthing - store exists, socket never connected,
      // error banners on screen, foreground service NOT started by the store.
      while (model.phase != AppPhase.noConnection) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(calls, isNot(contains('start')),
          reason: 'the store must not have started the service (it only '
              'starts on a LIVE connect)');
      var startSeenDuringFlow = false;
      // The quiet runner returns at once, so assert the boundary around the
      // whole call: start before, stop after, and the phase is mid-negotiation.
      final resolved = await model.signInOAuth(
        GatewayConfig(url: 'https://gw.example.com:9119'),
      );
      startSeenDuringFlow = calls.contains('start');
      expect(resolved.oauthToken, 'at-fake');
      expect(startSeenDuringFlow, isTrue,
          reason: 'issue #39 follow-up: with a failed store on screen the '
              'model held NO keep-alive and the phone reaped the app again');
      expect(calls.last, 'stop', reason: 'the service is released when the '
          'flow ends in this process');
      model.dispose();
    });
  });
}

OAuthFlowRunner _quietRunner() => _FakeRunner();

class _FakeRunner extends OAuthFlowRunner {
  _FakeRunner() : super(store: OAuthTokenStore());

  @override
  Future<NativeTokenSet> resolveToken(
    GatewayConfig config, {
    required Future<void> Function(Uri url) openBrowser,
    FutureOr<String> Function(String status)? onStatus,
    bool forceInteractive = false,
  }) async {
    return NativeTokenSet(
        accessToken: 'at-fake', refreshToken: '', expiresAt: 9999999999);
  }
}

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
}
