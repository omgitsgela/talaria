import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// A stopped turn must not leave anything spinning.
///
/// Reported: "If you send multiple interrupt messages over and over again,
/// previous messages get stuck in a rendering state in the conversation view.
/// If you stop execution of the turn, the indicator wheel will keep spinning on
/// old interrupted thinking blocks."
///
/// One flag explains both symptoms. `message.complete` is what marks an
/// assistant row finished, and an interrupted turn does not always deliver one,
/// so the row keeps `pending == true`, and BOTH spinners are gated on it:
///
///   isPending = message.pending && !hasContent   -> "Hermes is working…"
///   live: message.pending && identical(part, parts.last)  -> the trace spinner
///
/// Repeated interrupts therefore accumulate rows that each believe they are
/// still rendering. The store now seals them when the user stops the turn and
/// whenever the gateway authoritatively reports the session idle.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class R42Gateway extends GatewayClient {
  R42Gateway() : super(_cfg);
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
    _stateCtl.add(GwConnectionState.open);
  }

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    if (responses.containsKey(method)) return responses[method]!;
    return switch (method) {
      'session.create' => {'session_id': 'live-r42'},
      'session.resume' => {
          'session_id': 'live-r42',
          'resumed': 'stored-r42',
          'messages': const <Map<String, dynamic>>[],
        },
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'prompt.submit' => {'status': 'streaming'},
      // An interrupt the gateway accepts, and which delivers NO terminal event:
      // that is the case that used to leave a row spinning.
      'session.interrupt' => {'status': 'interrupted'},
      // The session is live and idle: an interrupt has taken effect. (An empty
      // list would mean the session is GONE, which is a different path: the
      // store drops the transcript.)
      'session.active_list' => {
          'sessions': [
            {'session_id': 'live-r42', 'status': 'idle'}
          ]
        },
      'session.usage' => {'context_used': 1000, 'context_max': 128000},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data,
          {String sid = 'live-r42'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
    await _stateCtl.close();
  }
}

Future<(R42Gateway, ChatStore)> _open(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1260, 2700);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final gw = R42Gateway();
  final store = ChatStore(config: _cfg, client: gw);
  addTearDown(store.dispose);
  await store.connect();
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
  await tester.pump();
  await store.resumeSession('stored-r42');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
  return (gw, store);
}

/// Fixed pumps: a running turn keeps a spinner animating, so pumpAndSettle hangs.
Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 60));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('repeated interrupts leave nothing spinning', (tester) async {
    final (gw, store) = await _open(tester);

    for (var turn = 0; turn < 3; turn++) {
      await store.send('turn $turn');
      // The assistant row is what carries the working indicator; it arrives
      // with message.start.
      gw.emit('message.start', {});
      await _settle(tester);
      // A turn with nothing to show yet is the rendering state.
      expect(find.byType(CircularProgressIndicator), findsWidgets,
          reason: 'a running turn shows the working indicator (turn $turn)');

      await store.interrupt();
      await _settle(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'after Stop nothing may keep spinning (turn $turn)');
    }

    expect(store.messages.where((m) => m.pending), isEmpty,
        reason: 'every interrupted row was sealed, not just the newest');
    expect(store.streaming, isFalse);
  });

  testWidgets('a stopped turn stops spinning its reasoning trace',
      (tester) async {
    final (gw, store) = await _open(tester);
    await store.send('a turn that thinks first');
    gw.emit('message.start', {});
    gw.emit('reasoning.delta', {'text': 'weighing the brake pad depth'});
    await _settle(tester);
    // The live trace itself spins while the turn runs.
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    await store.interrupt();
    await _settle(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'the interrupted thinking block must stop spinning');
    // The trace collapses once the turn is over, exactly like a completed
    // turn's does, so what matters is that the reasoning was not discarded.
    expect(store.messages.last.reasoning, contains('weighing the brake pad depth'),
        reason: 'what it thought must not be thrown away');
    expect(store.messages.where((m) => m.pending), isEmpty);
  });

  testWidgets('a normal completion still seals the row', (tester) async {
    // Guard against over-sealing: the ordinary path must keep working.
    final (gw, store) = await _open(tester);
    await store.send('an ordinary turn');
    gw.emit('message.start', {});
    await _settle(tester);
    gw.emit('message.complete', {'text': 'the answer'});
    await _settle(tester);
    expect(store.messages.where((m) => m.pending), isEmpty);
    expect(find.text('the answer'), findsWidgets);
  });
}
