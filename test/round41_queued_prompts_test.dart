import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Queued messages: the feedback that one is waiting, and the ability to change
/// it before it commits.
///
/// The queue is held by the APP, not handed to the gateway. The gateway keeps a
/// single queued prompt and offers no way to change or drop it, so a message
/// that lives there has already committed. Holding it here is what makes it
/// editable until the running turn ends, which is the whole request.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class QGateway extends GatewayClient {
  QGateway() : super(_cfg);
  final calls = <(String, Map<String, dynamic>)>[];
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => pushed.stream;
  @override
  Stream<GwConnectionState> get stateChanges => const Stream.empty();
  @override
  Future<void> connect({bool isReconnect = false}) async {}

  /// When set, prompt.submit fails: used for the "nothing is lost" case.
  bool failSubmit = false;

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    calls.add((method, params));
    if (method == 'prompt.submit' && failSubmit) {
      throw GatewayError('offline');
    }
    return switch (method) {
      'session.create' => {'session_id': 'live-q'},
      'session.resume' => {
          'session_id': 'live-q',
          'resumed': 'stored-q',
          'messages': const <Map<String, dynamic>>[],
        },
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'prompt.submit' => {'status': 'streaming'},
      'session.usage' => {'context_used': 1000, 'context_max': 128000},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data,
          {String sid = 'live-q'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  List<String> submittedTexts() => [
        for (final c in calls)
          if (c.$1 == 'prompt.submit') (c.$2['text'] ?? '').toString()
      ];

  @override
  Future<void> dispose() async {
    await pushed.close();
  }
}

/// A store with a turn already running, which is when queueing matters: the
/// whole point of /queue is to run after the CURRENT turn.
Future<(QGateway, ChatStore)> _busy() async {
  final pair = await _open();
  pair.$1.emit('message.start', {});
  await pair.$2.send('a turn is already running');
  return pair;
}

Future<(QGateway, ChatStore)> _open() async {
  SharedPreferences.setMockInitialValues({});
  final gw = QGateway();
  final store = ChatStore(config: _cfg, client: gw);
  addTearDown(store.dispose);
  await store.connect();
  await store.resumeSession('stored-q');
  return (gw, store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a queued message waits instead of being submitted', () async {
    final (gw, store) = await _busy();
    store.enqueuePrompt('do the thing next');

    expect(store.streaming, isTrue, reason: 'the turn must be running');
    expect(store.queuedPrompts, hasLength(1));
    expect(store.queuedPrompts.first.text, 'do the thing next');
    expect(gw.submittedTexts(), isNot(contains('do the thing next')),
        reason: 'a queued message must not be submitted while a turn runs');
  });

  test('the queue says so, so the user can see it is waiting', () async {
    final (_, store) = await _busy();
    store.enqueuePrompt('wait for it');
    expect(store.statusLine.toLowerCase(), contains('queued'));
  });

  test('a queued message can be edited before it commits', () async {
    final (gw, store) = await _open();
    // A turn is running, which is when queueing matters.
    gw.emit('message.start', {});
    store.enqueuePrompt('typo heer');
    final id = store.queuedPrompts.first.id;

    store.beginQueuedEdit(id);
    expect(store.editingQueuedId, id);
    // Sending while editing UPDATES the entry: it must not start a turn.
    final ok = await store.send('typo here');

    expect(ok, isTrue);
    expect(store.queuedPrompts, hasLength(1), reason: 'edited, not duplicated');
    expect(store.queuedPrompts.first.text, 'typo here');
    expect(store.editingQueuedId, isNull);
    expect(gw.submittedTexts(), isEmpty,
        reason: 'editing is not a turn: nothing has been sent yet');
  });

  test('clearing the box while editing drops the queued message', () async {
    final (_, store) = await _busy();
    store.enqueuePrompt('never mind');
    final id = store.queuedPrompts.first.id;
    store.beginQueuedEdit(id);
    await store.send('   ');
    expect(store.queuedPrompts, isEmpty);
    expect(store.editingQueuedId, isNull);
  });

  test('a queued message can be removed outright', () async {
    final (_, store) = await _busy();
    store.enqueuePrompt('drop me');
    store.removeQueuedPrompt(store.queuedPrompts.first.id);
    expect(store.queuedPrompts, isEmpty);
  });

  test('a queue made while nothing runs goes straight out', () async {
    final (gw, store) = await _open();
    store.enqueuePrompt('nothing is running');
    await Future<void>.delayed(Duration.zero);
    expect(store.queuedPrompts, isEmpty,
        reason: 'no turn to wait for, so it is sent');
    expect(gw.submittedTexts(), contains('nothing is running'));
  });

  test('the queue runs when the turn that blocked it ends', () async {
    final (gw, store) = await _open();
    gw.emit('message.start', {});
    await store.send('first turn');
    store.enqueuePrompt('after that');

    // The running turn finishes.
    gw.emit('message.complete', {'text': 'done'});
    await Future<void>.delayed(Duration.zero);

    expect(store.queuedPrompts, isEmpty, reason: 'it drained');
    expect(gw.submittedTexts(), contains('after that'));
  });

  test('nothing drains while a turn is still running', () async {
    final (gw, store) = await _open();
    gw.emit('message.start', {});
    await store.send('still running');
    store.enqueuePrompt('later');
    gw.emit('message.delta', {'text': 'more'});
    await Future<void>.delayed(Duration.zero);
    expect(store.queuedPrompts, hasLength(1));
    expect(gw.submittedTexts(), isNot(contains('later')));
  });

  test('send now submits a queued message and empties the entry', () async {
    final (gw, store) = await _busy();
    store.enqueuePrompt('send me now');
    final id = store.queuedPrompts.first.id;
    final ok = await store.sendQueuedPromptNow(id);
    expect(ok, isTrue);
    expect(gw.submittedTexts(), contains('send me now'));
    expect(store.queuedPrompts, isEmpty);
  });

  test('a send that fails leaves the message queued, not lost', () async {
    final (gw, store) = await _busy();
    store.enqueuePrompt('has to survive');
    final id = store.queuedPrompts.first.id;
    gw.failSubmit = true;
    final ok = await store.sendQueuedPromptNow(id);
    expect(ok, isFalse);
    expect(store.queuedPrompts, hasLength(1),
        reason: 'nothing the user wrote may be lost');
    expect(store.queuedPrompts.first.text, 'has to survive');
  });

  test('the queue survives an app restart', () async {
    SharedPreferences.setMockInitialValues({});
    final gw = QGateway();
    final first = ChatStore(config: _cfg, client: gw);
    await first.connect();
    await first.resumeSession('stored-q');
    gw.emit('message.start', {});
    await first.send('a turn is running');
    first.enqueuePrompt('remember me');
    // Let the write land.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    first.dispose();

    final second = ChatStore(config: _cfg, client: QGateway());
    addTearDown(second.dispose);
    await second.connect();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(second.queuedPrompts.map((q) => q.text), contains('remember me'));
  });
}
