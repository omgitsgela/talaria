import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:talaria/src/app_version.dart';
import 'package:talaria/src/gateway/http_service.dart';
import 'package:talaria/src/screens/connection_screen.dart';
import 'package:talaria/src/store/app_model.dart';

/// Serves the gateway's `/api/status` with whatever auth flows a test wants.
MockClient _statusClient(List<String> flows) => MockClient((request) async {
      if (request.url.path.endsWith('/api/status')) {
        return http.Response('{"auth_flows": ${_json(flows)}}', 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{}', 404);
    });

String _json(List<String> items) =>
    '[${items.map((i) => '"$i"').join(',')}]';

Widget _screen(AppModel model) => MaterialApp(home: ConnectionScreen(model: model));

void _phoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1260, 2700);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  tearDown(() => ConnectionScreen.httpFactoryForTest = null);

  testWidgets('the tagline is the shared one, not a local copy',
      (tester) async {
    _phoneSurface(tester);
    await tester.pumpWidget(_screen(AppModel()));
    await tester.pump(const Duration(milliseconds: 40));

    expect(find.text(kAppTagline), findsOneWidget,
        reason: 'the connection screen and the splash must agree');
    // The old hand-written line, which drifted from the splash, is gone.
    expect(find.textContaining('driven over the gateway WebSocket API'),
        findsNothing);
  });

  testWidgets('the mark is the app logo, not a generic icon', (tester) async {
    _phoneSurface(tester);
    await tester.pumpWidget(_screen(AppModel()));
    await tester.pump(const Duration(milliseconds: 40));

    expect(find.byIcon(Icons.flight_takeoff), findsNothing);
    final images = tester
        .widgetList<Image>(find.byType(Image))
        .where((i) => i.image is AssetImage)
        .map((i) => (i.image as AssetImage).assetName);
    expect(images, contains('assets/logo.png'));
  });

  testWidgets('field explanations are allowed to wrap instead of clipping',
      (tester) async {
    _phoneSurface(tester);
    await tester.pumpWidget(_screen(AppModel()));
    await tester.pump(const Duration(milliseconds: 40));

    // The session-token explanation is longer than one line on a phone. Flutter
    // ellipsizes a helper on one line unless helperMaxLines is set, which is
    // what hid most of this text.
    final helper = find.textContaining('X-Hermes-Session-Token');
    expect(helper, findsOneWidget);
    expect(tester.getSize(helper).height, greaterThan(20),
        reason: 'a single line is ~16px; wrapping is the whole point');
  });

  testWidgets('sign-in is offered without pressing Test connection',
      (tester) async {
    _phoneSurface(tester);
    // The gateway advertises the native PKCE flow, so the button belongs on
    // screen as soon as the URL is known.
    ConnectionScreen.httpFactoryForTest =
        (cfg) => GatewayHttp(cfg, client: _statusClient(const ['native_pkce']));

    await tester.pumpWidget(_screen(AppModel()));
    await tester.pump(const Duration(milliseconds: 40));

    // Before anything is typed, the field is a plain bearer field.
    expect(find.text('Sign in with Hermes'), findsNothing);

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Gateway URL'),
        'http://gateway.test:9119');
    // The discovery probe is debounced; nothing has been pressed.
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('Sign in with Hermes'), findsOneWidget,
        reason: 'discovery must not require the Test connection button');
    // Both routes in: pasting a token you already have is still possible.
    expect(find.widgetWithText(TextFormField, 'Bearer token'), findsOneWidget,
        reason: 'a manually minted bearer token must stay usable');
  });

  testWidgets('a gateway without the native flow keeps the plain token field',
      (tester) async {
    _phoneSurface(tester);
    ConnectionScreen.httpFactoryForTest =
        (cfg) => GatewayHttp(cfg, client: _statusClient(const []));

    await tester.pumpWidget(_screen(AppModel()));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Gateway URL'),
        'http://gateway.test:9119');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('Sign in with Hermes'), findsNothing,
        reason: 'this gateway offers no native flow, so nothing is promised');

    // The user picks the bearer route themselves when there is no flow to offer.
    await tester.tap(find.text('OAuth bearer'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.widgetWithText(TextFormField, 'Bearer token'), findsOneWidget);
    expect(find.textContaining('test the connection'), findsOneWidget,
        reason: 'the field should say how to find out about signing in');
  });
}
