import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/store/chat_store.dart';
import 'package:talaria/src/screens/home_screen.dart';

final _config = GatewayConfig(url: 'http://localhost:1');

/// Fake gateway for widget-level slash-command regression tests.
/// Tracks every RPC call and supplies configurable per-method responses.
class SlashGateway extends GatewayClient {
  SlashGateway() : super(_config);

  final calls = <(String, Map<String, dynamic>)>[];
  final responses = <String, Map<String, dynamic>>{};
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final _stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);

  @override
  GwConnectionState get state => GwConnectionState.open;

  @override
  Stream<GatewayEvent> get events => pushed.stream;

  @override
  Stream<GwConnectionState> get stateChanges => _stateCtl.stream;

  @override
  Future<void> connect({bool isReconnect = false}) async {
    // Emit connected so the store's _onState sets connection == open.
    _stateCtl.add(GwConnectionState.open);
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
    int timeoutMs = 120000,
  ]) async {
    calls.add((method, params));
    if (responses.containsKey(method)) return responses[method]!;
    // Sensible defaults that mirror the real gateway.
    if (method == 'session.create') {
      return {'session_id': 'live-draft'};
    }
    if (method == 'session.most_recent') {
      return {'session_id': null};
    }
    if (method == 'session.list') {
      return {'sessions': <Map<String, dynamic>>[]};
    }
    if (method == 'complete.slash') {
      return {'items': <Map<String, dynamic>>[]};
    }
    return const {};
  }

  /// Most recent call to [method], or null.
  (String, Map<String, dynamic>)? callFor(String method) {
    for (final c in calls.reversed) {
      if (c.$1 == method) return c;
    }
    return null;
  }

  bool called(String method) => calls.any((c) => c.$1 == method);

  @override
  Future<void> dispose() async {
    await pushed.close();
    await _stateCtl.close();
  }
}

/// Build a ChatStore wired to a [SlashGateway] and pump it into a
/// Material widget tree whose [HomeScreen] uses [storeOverride].
Future<(ChatStore, SlashGateway)> _pumpHome(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>>? responses,
}) async {
  final gw = SlashGateway();
  if (responses != null) gw.responses.addAll(responses);
  final store = ChatStore(config: _config, client: gw);
  addTearDown(store.dispose);

  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))),
  );

  // Drive the store to connected state (mirrors real connect()).
  gw.connect();
  await tester.pump();
  return (store, gw);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── Slash command routing ─────────────────────────────────────────

  testWidgets(
    'slash submission sends slash.exec NOT prompt.submit, '
    'result appears in SnackBar',
    (tester) async {
      final (store, gw) = await _pumpHome(tester, responses: {
        'session.create': {'session_id': 'live-a'},
        'slash.exec': {
          'output': 'Available commands:\n  compress  help  model',
        },
      });

      // Type a slash command.
      await tester.enterText(find.byType(TextField), '/help');
      await tester.pump();

      // Tap the send button.
      final sendBtn = find.byTooltip('Send');
      expect(sendBtn, findsOneWidget);
      await tester.tap(sendBtn);
      await tester.pumpAndSettle();

      // slash.exec was called with the raw command.
      final slash = gw.callFor('slash.exec');
      expect(slash, isNotNull);
      expect(slash!.$2['session_id'], 'live-a');
      expect(slash.$2['command'], '/help');

      // prompt.submit was NEVER called.
      expect(gw.called('prompt.submit'), isFalse);

      // The result text appears in a SnackBar.
      expect(
        find.text('Available commands:\n  compress  help  model'),
        findsOneWidget,
      );
    },
  );

  // ── Plain text routing ───────────────────────────────────────────

  testWidgets(
    'plain text sends prompt.submit NOT slash.exec',
    (tester) async {
      final (store, gw) = await _pumpHome(tester, responses: {
        'session.create': {'session_id': 'live-b'},
        'prompt.submit': {},
      });

      await tester.enterText(find.byType(TextField), 'hello world');
      await tester.pump();

      await tester.tap(find.byTooltip('Send'));
      // send() sets _streaming=true which starts MarqueeText's infinite
      // repeat animation, so pumpAndSettle would time out. Use a bounded
      // pump instead — the store state is synchronous.
      await tester.pump(const Duration(milliseconds: 100));

      // prompt.submit was called with the text.
      final submit = gw.callFor('prompt.submit');
      expect(submit, isNotNull);
      expect(submit!.$2['text'], 'hello world');

      // slash.exec was NEVER called.
      expect(gw.called('slash.exec'), isFalse);
    },
  );

  // ── Draft invocation ─────────────────────────────────────────────

  testWidgets(
    'slash in draft state materialises session via createSession '
    'before calling slash.exec',
    (tester) async {
      final (store, gw) = await _pumpHome(tester, responses: {
        'session.create': {'session_id': 'live-draft'},
        'slash.exec': {'output': 'Model: gpt-5'},
      });

      // No resume / no most_recent → activeSessionId is null (draft).
      expect(store.activeSessionId, isNull);

      await tester.enterText(find.byType(TextField), '/model');
      await tester.pump();

      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      // session.create was called (draft materialised).
      expect(gw.called('session.create'), isTrue);

      // slash.exec was called AFTER session.create.
      final createIdx =
          gw.calls.lastIndexWhere((c) => c.$1 == 'session.create');
      final slashIdx =
          gw.calls.lastIndexWhere((c) => c.$1 == 'slash.exec');
      expect(createIdx, lessThan(slashIdx));

      // session_id was set.
      expect(store.activeSessionId, 'live-draft');
    },
  );

  // ── Attachment preservation ──────────────────────────────────────

  testWidgets(
    'pending attachments survive a slash command (not consumed)',
    (tester) async {
      final (store, gw) = await _pumpHome(tester, responses: {
        'session.create': {'session_id': 'live-c'},
        'image.attach_bytes': {'path': '/staged/img.png'},
        'slash.exec': {'output': 'ok'},
      });

      // Stage an attachment before sending.
      await store.attachImageBytes([0xFF, 0xD8], filename: 'photo.jpg');
      expect(store.pendingAttachments, ['/staged/img.png']);

      // Send a slash command.
      await tester.enterText(find.byType(TextField), '/compress');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      // Attachment is still present — slash does not consume it.
      expect(store.pendingAttachments, ['/staged/img.png']);
    },
  );
}
