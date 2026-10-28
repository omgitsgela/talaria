import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/gateway/native_oauth.dart';
import 'package:talaria/src/gateway/oauth_flow.dart';
import 'package:talaria/src/store/app_model.dart';
import 'package:talaria/src/store/chat_store.dart';

NativeTokenSet tokens(String access) => NativeTokenSet(
    accessToken: access,
    refreshToken: 'refresh',
    expiresAt: 9999999999,
    provider: 'p',
    userId: 'u');

void main() {
  late FlutterSecureStoragePlatform original;
  setUp(() {
    original = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform({});
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = original;
    AppModel.clientFactoryForTest = null;
  });

  test('joined auth-rejected connects retain the typed auth failure', () async {
    final gw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final arrived = Completer<void>();
    final release = Completer<void>();
    gw.listen((req) async {
      arrived.complete();
      await release.future;
      req.response.statusCode = 401;
      req.response.write(jsonEncode({'error': 'session_expired'}));
      await req.response.close();
    });
    final cfg =
        GatewayConfig(url: 'http://127.0.0.1:${gw.port}', oauthToken: 'dead');
    final client = GatewayClient(cfg);
    final store = ChatStore(config: cfg, client: client);
    addTearDown(() async {
      store.dispose();
      await gw.close(force: true);
    });
    final first = store.connect();
    final firstCheck = expectLater(first, throwsA(isA<GatewayAuthError>()));
    await arrived.future;
    final joined = store.connect();
    final joinedOutcome =
        joined.then<Object?>((_) => null, onError: (Object e) => e);
    release.complete();
    await firstCheck;
    final error = await joinedOutcome;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(store.needsReauth, isTrue,
        reason:
            'a joined connect must not downgrade authRequired to generic error');
    expect(error, isA<GatewayAuthError>());
  });

  test('background auth rejection invalidates OAuth just like explicit connect',
      () async {
    final gw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    gw.listen((req) async {
      req.response.statusCode = 401;
      req.response.write(jsonEncode({'error': 'session_expired'}));
      await req.response.close();
    });
    final cfg =
        GatewayConfig(url: 'http://127.0.0.1:${gw.port}', oauthToken: 'dead');
    final runner = OAuthFlowRunner(store: OAuthTokenStore());
    await runner.store.save(cfg.baseUrl, tokens('dead'));
    final client = GatewayClient(cfg);
    final store = ChatStore(config: cfg, client: client, oauthRunner: runner);
    addTearDown(() async {
      store.dispose();
      await gw.close(force: true);
    });
    // This is the same client entry used by its backoff timer, without the
    // explicit ChatStore.connect wrapper. The store receives stateChanges.
    await expectLater(
        client.connect(isReconnect: true), throwsA(isA<GatewayAuthError>()));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(store.needsReauth, isTrue);
    expect(cfg.oauthToken, isEmpty,
        reason: 'background auth must clear the rejected bearer');
    expect(await runner.store.load(cfg.baseUrl), isNull);
  });

  test('late rejection cleanup cannot delete a newly signed-in token',
      () async {
    final storage = _DelayedClearStore();
    final cfg = GatewayConfig(url: 'https://gw.example', oauthToken: 'dead');
    final runner = OAuthFlowRunner(store: storage);
    await storage.save(cfg.baseUrl, tokens('dead'));
    final store =
        ChatStore(config: cfg, client: _RejectClient(cfg), oauthRunner: runner);
    addTearDown(store.dispose);
    await expectLater(store.connect(), throwsA(isA<GatewayAuthError>()));
    await storage.entered.future;
    await storage.save(cfg.baseUrl, tokens('fresh'));
    storage.release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect((await storage.load(cfg.baseUrl))?.accessToken, 'fresh');
    expect(await storage.reauthNeededReason(cfg.baseUrl), isNull);
  });

  test(
      'cancel during browser launch completes the flow without waiting for launch',
      () async {
    final runner = OAuthFlowRunner(store: OAuthTokenStore());
    final entered = Completer<void>();
    final launch = Completer<void>();
    var finished = false;
    final flow = runner.signIn(GatewayConfig(url: 'https://gw.example'),
        openBrowser: (_) {
      entered.complete();
      return launch.future;
    });
    final observed = flow.then<Object?>((v) {
      finished = true;
      return v;
    }, onError: (Object e) {
      finished = true;
      return e;
    });
    await entered.future;
    await runner.cancelActiveSignIn();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final completedOnCancel = finished;
    launch.complete();
    await observed;
    expect(completedOnCancel, isTrue,
        reason: 'cancel must release the caller, not only repaint the form');
  });

  test('cancel during token exchange cannot still persist a signed-in session',
      () async {
    final entered = Completer<void>();
    final reply = Completer<http.Response>();
    final storage = OAuthTokenStore();
    final runner = OAuthFlowRunner(
        store: storage,
        httpClient: MockClient((req) {
          entered.complete();
          return reply.future;
        }));
    const base = 'https://gw.example';
    final flow =
        runner.signIn(GatewayConfig(url: base), openBrowser: (url) async {
      final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
      await http.get(redirect.replace(queryParameters: {
        'code': 'code',
        'state': url.queryParameters['state']!,
      }));
    });
    final observed = flow.then<Object?>((v) => v, onError: (Object e) => e);
    await entered.future;
    await runner.cancelActiveSignIn();
    reply.complete(http.Response(
        jsonEncode({
          'access_token': 'fresh',
          'refresh_token': 'refresh',
          'expires_in': 3600,
          'provider': 'p',
          'user_id': 'u',
        }),
        200));
    final outcome = await observed;
    expect(outcome, isA<OAuthException>(),
        reason: 'Cancel cannot be followed by silent successful sign-in');
    expect(await storage.load(base), isNull);
  });

  test('Home reauth preserves the current ChatStore and transcript owner',
      () async {
    AppModel.clientFactoryForTest = (cfg) => _SuccessClient(cfg);
    final model = AppModel(oauthRunner: _ImmediateRunner());
    addTearDown(model.dispose);
    await model
        .connect(GatewayConfig(url: 'https://gw.example', oauthToken: 'old'));
    final originalStore = model.store!;
    expect(await originalStore.resumeSession('chosen-conversation'), isTrue);
    expect(originalStore.messages.map((m) => m.text),
        contains('keep this transcript'));
    expect(await model.reauthSignIn(), isTrue);
    expect(model.store!.activeStoredSessionId, 'chosen-conversation',
        reason: 'reauth must return to the conversation that was open');
    expect(model.store!.messages.map((m) => m.text),
        contains('keep this transcript'));
  });
}

class _DelayedClearStore extends OAuthTokenStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> deleteTokenRecord(String baseUrl,
      {int expectedRevision = -1}) async {
    entered.complete();
    await release.future;
    await super.deleteTokenRecord(baseUrl,
        expectedRevision: expectedRevision);
  }
}

class _RejectClient extends GatewayClient {
  _RejectClient(super.config);
  @override
  Future<void> connect({bool isReconnect = false}) async {
    throw GatewayAuthError('rejected', sessionExpired: true);
  }
}

class _SuccessClient extends GatewayClient {
  _SuccessClient(super.config);
  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Future<void> connect({bool isReconnect = false}) async {}
  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    if (method == 'session.create') return {'session_id': 'live'};
    if (method == 'session.resume') {
      return {
        'session_id': 'resumed-live',
        'resumed': params['session_id'],
        'messages': [
          {'role': 'user', 'text': 'keep this transcript'}
        ],
      };
    }
    return {};
  }
}

class _ImmediateRunner extends OAuthFlowRunner {
  _ImmediateRunner() : super(store: OAuthTokenStore());
  @override
  Future<NativeTokenSet> resolveToken(
    GatewayConfig config, {
    required Future<void> Function(Uri) openBrowser,
    FutureOr<String> Function(String)? onStatus,
    bool forceInteractive = false,
  }) async =>
      tokens('fresh');
}
