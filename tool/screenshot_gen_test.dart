// Screenshot / teaser generator for the README and release pages.
//
// NOT part of the CI suite: `flutter test` only discovers `test/**`, and this
// file lives in `tool/`, so a UI tweak can never fail CI on a stale golden.
//
// Regenerate with:
//   flutter test --update-goldens tool/screenshot_gen_test.dart
//
// Images land in `docs/screenshots/`. They are renders of the real widgets with
// the real theme at phone size, using fixture data only (no personal content),
// with Roboto and MaterialIcons loaded from the local Flutter SDK so text and
// icons look the way they do on an Android device.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/screens/settings_screen.dart';
import 'package:talaria/src/screens/splash_screen.dart';
import 'package:talaria/src/store/chat_store.dart';
import 'package:talaria/src/theme/app_theme.dart';

final _cfg = GatewayConfig(url: 'http://gw.example.internal:9119');

/// 420x900 logical at 3x: a typical modern Android phone.
const Size _phone = Size(1260, 2700);
const double _dpr = 3.0;

Future<void> _loadFontFamily(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var added = false;
  for (final p in paths) {
    final f = File(p);
    if (!f.existsSync()) continue;
    loader.addFont(f.readAsBytes().then((b) => ByteData.view(b.buffer)));
    added = true;
  }
  if (added) await loader.load();
}

/// Real fonts so text is legible and icons are icons (the test environment's
/// default font renders glyph boxes). Resolved from FLUTTER_ROOT, which the
/// flutter tool exports, so nothing machine-specific is baked in.
Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null || root.isEmpty) {
    // ignore: avoid_print
    print('FLUTTER_ROOT unset; screenshots will use the test font');
    return;
  }
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) {
    // ignore: avoid_print
    print('material_fonts missing under $root; using the test font');
    return;
  }
  String p(String name) => '${dir.path}/$name';
  await _loadFontFamily('Roboto', [
    p('Roboto-Regular.ttf'),
    p('Roboto-Medium.ttf'),
    p('Roboto-Bold.ttf'),
    p('Roboto-Black.ttf'),
  ]);
  await _loadFontFamily('MaterialIcons', [p('MaterialIcons-Regular.otf')]);
}

/// Screenshot-facing fake gateway: answers just enough for the screens, with
/// fixture data that contains nothing personal.
class ShotGateway extends GatewayClient {
  ShotGateway() : super(_cfg);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => pushed.stream;
  @override
  Stream<GwConnectionState> get stateChanges => stateCtl.stream;
  @override
  Future<void> connect({bool isReconnect = false}) async {
    stateCtl.add(GwConnectionState.open);
  }

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    switch (method) {
      case 'session.resume':
        return {
          'session_id': 'rt-1',
          'resumed': params['session_id'],
          'messages': const <Map<String, dynamic>>[],
          'running': false,
          'info': {
            'model': 'qwen3-32b',
            'provider': 'llamacpp-qwen38',
            'reasoning_effort': 'medium',
          },
        };
      case 'session.usage':
        return {'context_used': 24500, 'context_max': 128000, 'context_percent': 19};
      case 'session.active_list':
        return {'sessions': const <Map<String, dynamic>>[]};
      case 'slash.exec':
        return {'output': 'No active goal. Set one with /goal <text>.'};
      case 'session.list':
        return {'sessions': _roster};
      case 'config.get':
        final key = params['key'];
        if (key == 'model') return {'value': 'qwen3-32b'};
        if (key == 'reasoning') return {'value': 'medium', 'display': 'show'};
        if (key == 'fast') return {'value': 'normal'};
        return {'value': ''};
      case 'model.options':
        return {
          'providers': [
            {
              'slug': 'llamacpp-qwen38',
              'name': 'Local (llama.cpp)',
              'models': [
                {'slug': 'qwen3-32b', 'label': 'qwen3-32b', 'authenticated': true},
                {'slug': 'mistral-small', 'label': 'mistral-small', 'authenticated': true},
              ],
            },
          ],
        };
      default:
        return {};
    }
  }

  /// Roster rows for the sessions sheet: a pinned conversation plus buckets.
  static List<Map<String, dynamic>> get _roster => [
        {
          'id': 'demo-conv-0001',
          'title': 'Nightly log parsing script',
          'preview': 'Added the retry guard and a dry-run flag.',
          'started_at': _daysAgo(0),
          'message_count': 42,
        },
        {
          'id': 'demo-conv-0002',
          'title': 'Photo batch rename',
          'preview': 'Renamed 128 files by capture date.',
          'started_at': _daysAgo(0),
          'message_count': 12,
        },
        {
          'id': 'demo-conv-0003',
          'title': 'Coolant temp sensor notes',
          'preview': 'Resistance table for the new sensor.',
          'started_at': _daysAgo(1),
          'message_count': 27,
        },
        {
          'id': 'demo-conv-0004',
          'title': 'Drone flight log review',
          'preview': 'Wind was the limiting factor on leg 3.',
          'started_at': _daysAgo(4),
          'message_count': 63,
        },
      ];

  static double _daysAgo(int d) =>
      DateTime.now().subtract(Duration(days: d)).millisecondsSinceEpoch / 1000.0;

  void emit(String type, Map<String, dynamic> data, {String sid = 'rt-1'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
    await stateCtl.close();
  }
}

Future<ChatStore> _openStore(ShotGateway gw) async {
  final store = ChatStore(config: _cfg, client: gw);
  await store.connect();
  await store.resumeSession('demo-conv-0001');
  return store;
}

Future<void> _settle(WidgetTester tester, [int frames = 3]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadFonts();
  });

  void sizeToPhone(WidgetTester tester) {
    tester.view.physicalSize = _phone;
    tester.view.devicePixelRatio = _dpr;
    addTearDown(tester.view.reset);
  }

  /// Every shot uses the app's own dark theme so the images match the product.
  Widget themed(Widget child) => MaterialApp(
        // Never ship a shot with Flutter's red DEBUG ribbon in the corner.
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.dark,
        home: child,
      );

  testWidgets('01 splash', (tester) async {
    sizeToPhone(tester);
    await tester.pumpWidget(themed(SplashOverlay(
      child: Scaffold(backgroundColor: AppTheme.dark().colorScheme.surface),
    )));
    await _settle(tester, 6);
    // Asset images decode off the main isolate: without an explicit precache
    // the logo slot paints empty in the golden.
    await tester.runAsync(() async {
      await precacheImage(
          const AssetImage('assets/logo.png'),
          tester.element(find.byType(SplashOverlay)));
    });
    await _settle(tester, 4);
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('../docs/screenshots/01-splash.png'));
  });

  testWidgets('02 transcript with thinking, tools and the context readout',
      (tester) async {
    sizeToPhone(tester);
    final gw = ShotGateway();
    final store = await _openStore(gw);
    addTearDown(store.dispose);
    await tester.pumpWidget(
        themed(Scaffold(body: HomeScreen(storeOverride: store))));
    await tester.pump();

    // Fixture conversation: request, thinking, a tool call, then the summary.
    gw.emit('message.start', const {});
    gw.emit('message.delta', {'text': 'Which logs should I parse first?'});
    gw.emit('message.interim', {'text': 'Which logs should I parse first?', 'already_streamed': true});
    gw.emit('message.start', const {});
    gw.emit('thinking.delta',
        {'text': 'The nightly file is the one that grew, so start there and keep the parser streaming.'});
    gw.emit('tool.start', {
      'name': 'terminal',
      'tool_id': 't1',
      'preview': r"python3 parse_logs.py --since 2026-09-15 --dry-run",
    });
    gw.emit('tool.complete', {'tool_id': 't1'});
    gw.emit('message.start', const {});
    gw.emit('message.delta', {
      'text': 'Parsed the 15th first: 42,318 lines, 12 malformed, and the retry guard '
          'catches all 12. The dry run writes nothing, so it is safe to repeat.',
    });
    gw.emit('message.complete', {
      'text': 'Parsed the 15th first: 42,318 lines, 12 malformed, and the retry guard '
          'catches all 12. The dry run writes nothing, so it is safe to repeat.',
      'usage': {'context_used': 24500, 'context_max': 128000, 'context_percent': 19},
    });
    await _settle(tester, 6);

    await expectLater(find.byType(HomeScreen),
        matchesGoldenFile('../docs/screenshots/02-transcript.png'));
  });

  testWidgets('03 conversations roster', (tester) async {
    sizeToPhone(tester);
    final gw = ShotGateway();
    final store = await _openStore(gw);
    addTearDown(store.dispose);
    await tester.pumpWidget(
        themed(Scaffold(body: HomeScreen(storeOverride: store))));
    await tester.pump();
    await store.loadSessions();
    await _settle(tester, 4);

    await tester.tap(find.byTooltip('Sessions'));
    await _settle(tester, 8);

    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../docs/screenshots/03-roster.png'));
  });

  testWidgets('04 model and settings', (tester) async {
    sizeToPhone(tester);
    final gw = ShotGateway();
    final store = await _openStore(gw);
    addTearDown(store.dispose);
    await tester.pumpWidget(themed(SettingsScreen(store: store)));
    await _settle(tester, 8);

    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../docs/screenshots/04-settings.png'));
  });
}
