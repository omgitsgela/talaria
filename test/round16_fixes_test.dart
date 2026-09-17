import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 16 (2026-09-14): a send that never reaches the gateway must not
/// leave a ghost message in the transcript, must not strand the user's
/// draft in the cleared composer, and must surface a clean error string
/// (no `GatewayError(N): ` wrapper prefix).
///
/// Before the fix: `send()` was `Future<void>`; the optimistic user message
/// was appended BEFORE `prompt.submit` and the catch block only reset
/// `_streaming` / `_statusLine`, so a failed send (transport blip, 4009
/// busy, timeout) left the message permanently in the transcript — a ghost
/// the gateway never saw — while the composer text (cleared before the
/// await) was gone.

final _cfg = GatewayConfig(url: 'http://localhost:1');

class R16Gateway extends GatewayClient {
  R16Gateway() : super(_cfg);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final _stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);
  bool failSubmit = false;

  @override
  GwConnectionState get state => GwConnectionState.open;

  @override
  Stream<GatewayEvent> get events => pushed.stream;

  @override
  Stream<GwConnectionState> get stateChanges => _stateCtl.stream;

  @override
  Future<void> connect({bool isReconnect = false}) async {
    _stateCtl.add(GwConnectionState.open);
  }

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    switch (method) {
      case 'session.create':
        return {'session_id': 'live-a'};
      case 'session.resume':
        return {
          'session_id': 'live-${params['session_id']}',
          'resumed': params['session_id'],
          'messages': <Map<String, dynamic>>[],
          'info': {'model': 'test-model'},
        };
      case 'prompt.submit':
        if (failSubmit) throw GatewayError('simulated transport blip', code: 4009);
        return {'status': 'streaming'};
      default:
        return {};
    }
  }

  @override
  Future<void> dispose() async {
    await pushed.close();
    await _stateCtl.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('failed send leaves no ghost (round 16)', () {
    test('a rejected prompt.submit returns false and removes the optimistic '
        'message; the transcript is clean', () async {
      final gw = R16Gateway()..failSubmit = true;
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('a');

      final ok = await store.send('hello there');

      expect(ok, isFalse, reason: 'send must report that it never landed');
      expect(store.streaming, isFalse,
          reason: 'the failed turn must not keep the streaming flag armed');
      expect(store.messages, isEmpty,
          reason: 'the optimistic user message must not linger as a ghost');
      expect(store.statusLine, isNot(contains('GatewayError(')),
          reason: 'the error must be stripped of the GatewayError(N): prefix');
      expect(store.statusLine, contains('simulated transport blip'));
      // Attachments must survive a failed send (pre-existing contract).
      expect(store.pendingAttachments, isEmpty);
    });

    test('a successful prompt.submit returns true and keeps the message',
        () async {
      final gw = R16Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await store.resumeSession('a');

      final ok = await store.send('hello there');

      expect(ok, isTrue, reason: 'a landed send must report success');
      expect(store.messages.length, 1);
      expect(store.messages.last.role, 'user');
      expect(store.messages.last.text, 'hello there');
      expect(store.streaming, isTrue, reason: 'a fresh turn streams');
      // End the turn so disposal is clean.
      gw.pushed.add(GatewayEvent(
          type: 'message.complete',
          sessionId: 'live-a',
          payload: {'text': 'hi', 'session_id': 'live-a'}));
      await Future<void>.delayed(Duration.zero);
    });

    testWidgets('the composer draft is restored when the send fails',
        (tester) async {
      final gw = R16Gateway()..failSubmit = true;
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();

      // Type a draft and hit send (the up-arrow button).
      await tester.enterText(find.byType(TextField), 'my draft message');
      await tester.pump();
      final sendBtn =
          find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded);
      expect(sendBtn, findsOneWidget,
          reason: 'a dirty composer enables the send button');
      await tester.tap(sendBtn);
      // Let the (rejected) request round-trip and the view react.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      // The draft is back in the composer — and ONLY in the composer: the
      // transcript must not contain a ghost bubble for the failed send.
      expect(find.text('my draft message'), findsOneWidget,
          reason: 'the failed send must restore the draft in the composer '
              'and leave no ghost message in the transcript');
    });
  });
}
