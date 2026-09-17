import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Clarify / approval cards (Round 25).
///
/// The gateway emits TWO clarify shapes (`tui_gateway/server.py` `_clarify_block`):
///
///   * single question: `{request_id, question, choices}` (+ `multi_select`)
///   * batch form:      `{request_id, questions: [{qid, question, choices,
///                        multi_select}]}`
///
/// and resolves replies by `request_id` (`_respond`): a reply carrying only
/// `session_id` is rejected with 4009 "no pending clarify request".
///
/// Talaria used to send `{session_id, answer}` with no `request_id`, so every
/// reply was rejected, the catch re-armed the card, and the prompt stayed on
/// screen forever (returning on every resume). It was visible as a card whose
/// question text had fallen back to "Hermes needs your input" and whose only
/// button was "No", because the batch shape was not understood either.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class R25Gateway extends GatewayClient {
  R25Gateway() : super(_cfg);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];

  /// Rows `clarify.respond` reports as still unanswered.
  List<String> remainingAfterAnswer = const [];
  /// When set, every respond call fails with this gateway error code.
  int? failRespondWith;

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
    calls.add((method, params));
    switch (method) {
      case 'session.resume':
        return {
          'session_id': 'rt-1',
          'resumed': params['session_id'],
          'messages': const <Map<String, dynamic>>[],
          'info': {'model': 'test-model'},
        };
      case 'clarify.respond':
        if (failRespondWith != null) {
          throw GatewayError('no pending clarify request', code: failRespondWith);
        }
        return {'status': 'ok', 'remaining': remainingAfterAnswer};
      case 'approval.respond':
        if (failRespondWith != null) {
          throw GatewayError('no pending approval request', code: failRespondWith);
        }
        return {'status': 'ok'};
      case 'session.list':
        return {'sessions': const <Map<String, dynamic>>[]};
      case 'session.active_list':
        return {'sessions': const <Map<String, dynamic>>[]};
      default:
        return {};
    }
  }

  Map<String, dynamic>? lastParams(String method) {
    for (final c in calls.reversed) {
      if (c.$1 == method) return c.$2;
    }
    return null;
  }

  int countOf(String method) => calls.where((c) => c.$1 == method).length;

  void emit(String type, Map<String, dynamic> data, {String sid = 'rt-1'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
    await stateCtl.close();
  }
}

Future<ChatStore> _open(R25Gateway gw) async {
  final store = ChatStore(config: _cfg, client: gw);
  await store.connect();
  await store.resumeSession('stored-x');
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('clarify replies address the request by id (round 25)', () {
    test('a single-question answer carries request_id', () async {
      final gw = R25Gateway();
      final store = await _open(gw);
      addTearDown(store.dispose);
      store.pendingRequest = GatewayEvent(
        type: 'clarify.request',
        sessionId: 'rt-1',
        payload: {
          'request_id': 'req-1',
          'question': 'Which file?',
          'choices': ['a.dart', 'b.dart'],
        },
      );

      await store.respondApproval(approved: true, choice: 'a.dart');

      final sent = gw.lastParams('clarify.respond');
      expect(sent, isNotNull);
      expect(sent!['request_id'], 'req-1',
          reason: 'without request_id the gateway rejects the reply (4009) and '
              'the card can never be cleared');
      expect(sent['answer'], 'a.dart');
      expect(store.pendingRequest, isNull,
          reason: 'a whole-request answer clears the card');
    });

    test('a batch question is answered by question_id and keeps the card '
        'until the last question is locked', () async {
      final gw = R25Gateway()..remainingAfterAnswer = ['q2'];
      final store = await _open(gw);
      addTearDown(store.dispose);
      store.pendingRequest = GatewayEvent(
        type: 'clarify.request',
        sessionId: 'rt-1',
        payload: {
          'request_id': 'req-2',
          'questions': [
            {'qid': 'q1', 'question': 'First?', 'choices': ['x', 'y'], 'multi_select': false},
            {'qid': 'q2', 'question': 'Second?', 'choices': ['p', 'q'], 'multi_select': false},
          ],
        },
      );

      await store.respondApproval(approved: true, choice: 'x', questionId: 'q1');

      final first = gw.lastParams('clarify.respond');
      expect(first!['request_id'], 'req-2');
      expect(first['question_id'], 'q1');
      expect(first['answer'], 'x');
      expect(store.clarifyAnswers['q1'], 'x',
          reason: 'the answered question is ticked');
      expect(store.pendingRequest, isNotNull,
          reason: 'the card stays while other questions are unanswered');

      // Now the last one.
      gw.remainingAfterAnswer = const [];
      await store.respondApproval(approved: true, choice: 'p', questionId: 'q2');
      expect(store.pendingRequest, isNull);
      expect(store.clarifyAnswers, isEmpty);
    });

    test('a reply the gateway no longer knows clears the card instead of '
        'sticking', () async {
      final gw = R25Gateway()..failRespondWith = 4009;
      final store = await _open(gw);
      addTearDown(store.dispose);
      store.pendingRequest = GatewayEvent(
        type: 'clarify.request',
        sessionId: 'rt-1',
        payload: {
          'request_id': 'req-3',
          'questions': [
            {'qid': 'q1', 'question': 'Still there?', 'choices': ['yes'], 'multi_select': false},
          ],
        },
      );

      await store.respondApproval(approved: true, choice: 'yes', questionId: 'q1');

      expect(store.pendingRequest, isNull,
          reason: 'a stale request must not trap the user behind a card that '
              'cannot be answered');
      expect(store.statusLine, isNot(contains('not sent')),
          reason: 'a gone request is not a transport failure');
    });

    test('dismissing cancels a batch without answering it', () async {
      final gw = R25Gateway();
      final store = await _open(gw);
      addTearDown(store.dispose);
      store.pendingRequest = GatewayEvent(
        type: 'clarify.request',
        sessionId: 'rt-1',
        payload: {
          'request_id': 'req-4',
          'questions': [
            {'qid': 'q1', 'question': 'Answer me?', 'choices': ['a'], 'multi_select': false},
          ],
        },
      );

      await store.dismissPendingRequest();

      final sent = gw.lastParams('clarify.respond');
      expect(sent!['request_id'], 'req-4');
      expect(sent.containsKey('question_id'), isFalse,
          reason: 'no question_id = cancel-all for a batch');
      expect(store.pendingRequest, isNull);
    });

    test('an approval reply carries request_id and an advertised choice',
        () async {
      final gw = R25Gateway();
      final store = await _open(gw);
      addTearDown(store.dispose);
      store.pendingRequest = GatewayEvent(
        type: 'approval.request',
        sessionId: 'rt-1',
        payload: {
          'request_id': 'req-5',
          'command': 'rm -rf /tmp/x',
          'choices': ['once', 'session', 'always', 'deny'],
        },
      );

      await store.respondApproval(approved: true, choice: 'always');

      final sent = gw.lastParams('approval.respond');
      expect(sent!['request_id'], 'req-5');
      expect(sent['choice'], 'always');
      expect(store.pendingRequest, isNull);
    });

    test('a prompt without a request id is cleared, not left stuck', () async {
      final gw = R25Gateway();
      final store = await _open(gw);
      addTearDown(store.dispose);
      store.pendingRequest = GatewayEvent(
        type: 'clarify.request',
        sessionId: 'rt-1',
        payload: {'question': 'No id here'},
      );

      await store.respondApproval(approved: true, choice: 'x');

      expect(gw.countOf('clarify.respond'), 0,
          reason: 'there is nothing addressable to reply to');
      expect(store.pendingRequest, isNull,
          reason: 'an unanswerable card must still be dismissable');
    });

    test('clarify.expire clears the matching card', () async {
      final gw = R25Gateway();
      final store = await _open(gw);
      addTearDown(store.dispose);
      store.pendingRequest = GatewayEvent(
        type: 'clarify.request',
        sessionId: 'rt-1',
        payload: {'request_id': 'req-6', 'question': 'Still waiting?'},
      );

      gw.emit('clarify.expire', {'request_id': 'req-6'});

      expect(store.pendingRequest, isNull,
          reason: 'the gateway retired the request; the card must go with it');
    });
  });

  group('the request card understands every payload shape (round 25)', () {
    testWidgets('a batch form renders each question instead of the fallback',
        (tester) async {
      tester.view.physicalSize = const Size(1260, 2700);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final gw = R25Gateway();
      final store = await _open(gw);
      addTearDown(store.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();

      store.pendingRequest = GatewayEvent(
        type: 'clarify.request',
        sessionId: 'rt-1',
        payload: {
          'request_id': 'req-7',
          'questions': [
            {'qid': 'q1', 'question': 'Which colour?', 'choices': ['red', 'blue'], 'multi_select': false},
            {'qid': 'q2', 'question': 'Which size?', 'choices': ['small', 'large'], 'multi_select': false},
          ],
        },
      );
      await tester.pump();

      expect(find.text('Which colour?'), findsOneWidget);
      expect(find.text('Which size?'), findsOneWidget);
      expect(find.text('red'), findsOneWidget);
      expect(find.text('large'), findsOneWidget);
      expect(find.text('Hermes needs your input'), findsNothing,
          reason: 'the fallback text was the visible symptom of the bug');
    });

    testWidgets('an approval renders its advertised choices', (tester) async {
      tester.view.physicalSize = const Size(1260, 2700);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final gw = R25Gateway();
      final store = await _open(gw);
      addTearDown(store.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();

      store.pendingRequest = GatewayEvent(
        type: 'approval.request',
        sessionId: 'rt-1',
        payload: {
          'request_id': 'req-8',
          'command': 'rm -rf /tmp/x',
          'choices': ['once', 'session', 'always', 'deny'],
        },
      );
      await tester.pump();

      expect(find.text('Allow once'), findsOneWidget);
      expect(find.text('Always allow'), findsOneWidget);
      expect(find.text('Deny'), findsOneWidget);
    });
  });
}
