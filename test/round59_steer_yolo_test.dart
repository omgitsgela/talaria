import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/store/chat_store.dart';

/// /steer and /yolo must feel the same every time they are used.
///
/// Angela's 1.4.0 report: "/steer and /yolo are inconsistent experiences."
/// Verified against the live gateway (tui_gateway):
///
/// /steer (_cmd_steer, methods_tools.py): THREE outcomes — running+steerable
/// returns an exec line ("Steer queued - arrives after the next tool call"),
/// idle returns a `send` WITH a notice ("No agent running; sent as next
/// turn"), and a refused steer returns a bare `send`. The notice-carrying
/// send was invisible in-app: the store set only `_statusLine` (the status
/// pill was removed in build 23, so nothing renders it), so the same command
/// produced feedback sometimes and silence other times. Rule now: a
/// notice-carrying dispatch always reaches `notices` (the SnackBar channel).
///
/// /yolo: the gateway's verified toggle is `config.set {key:'yolo',
/// session_id}` (_set_yolo: toggles the SESSION flag, answers with the
/// computed value '1'/'0', and emits session.info). Talaria routed the text
/// command through the slash worker instead, so nothing verified the TARGET,
/// the banner depended on an unrelated session.info arriving later, and
/// `_yoloActive` was never re-read on a conversation switch (resume carries
/// `info.yolo`; `_resetTrackedStatus` ignored it) — so the banner showed the
/// PREVIOUS conversation's yolo state. Desktop maps /yolo to exactly the
/// config.set call (slash.ts setSessionYolo); Talaria now does the same.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class SGateway extends GatewayClient {
  SGateway() : super(_cfg);
  final calls = <(String, Map<String, dynamic>)>[];
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);

  /// The gateway's per-session yolo flag; session.info reports it, like the
  /// real gateway computes it from all three sources.
  bool yoloFlag = false;

  /// What `/steer <arg>` answers, to drive each real outcome in turn.
  Map<String, dynamic> steerReply = {'type': 'exec', 'output': 'steered ok'};

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => pushed.stream;
  @override
  Stream<GwConnectionState> get stateChanges => const Stream.empty();
  @override
  Future<void> connect({bool isReconnect = false}) async {}

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    calls.add((method, params));
    return switch (method) {
      'session.resume' => {
          'session_id': 'live-1',
          'resumed': 'stored-1',
          'running': false,
          'info': {
            'model': 'm',
            'yolo': yoloFlag,
          },
          'messages': const <Map<String, dynamic>>[],
        },
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'session.active_list' => {
          'sessions': [
            {'id': 'live-1', 'session_key': 'stored-1'}
          ]
        },
      'slash.exec' => steerReply,
      'config.set' => switch (params['key']) {
          'yolo' => _toggleYolo(params),
          _ => {'value': ''},
        },
      'config.get' => {'value': yoloFlag ? '1' : '0'},
      'prompt.submit' => {'status': 'streaming'},
      'session.usage' => {'context_used': 1, 'context_max': 2},
      _ => <String, dynamic>{},
    };
  }

  Map<String, dynamic> _toggleYolo(Map<String, dynamic> params) {
    final raw = (params['value'] ?? '').toString();
    // Mirror the gateway's toggle semantics: explicit value wins, empty
    // value flips the current flag.
    yoloFlag = switch (raw) {
      '1' || 'on' || 'true' || 'yes' => true,
      '0' || 'off' || 'false' || 'no' => false,
      _ => !yoloFlag,
    };
    // And emit the session.info echo exactly like _set_yolo does.
    pushed.add(GatewayEvent(
        type: 'session.info',
        sessionId: 'live-1',
        payload: {'yolo': yoloFlag}));
    return {'value': yoloFlag ? '1' : '0', 'scope': 'session'};
  }

  void emit(String type, Map<String, dynamic> data) =>
      pushed.add(GatewayEvent(type: type, sessionId: 'live-1', payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
  }
}

Future<(SGateway, ChatStore)> _open() async {
  SharedPreferences.setMockInitialValues({});
  final gw = SGateway();
  final store = ChatStore(config: _cfg, client: gw);
  addTearDown(store.dispose);
  await store.connect();
  await store.resumeSession('stored-1');
  return (gw, store);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('/steer feedback is consistent across all three gateway outcomes',
      () {
    test('running steer: the exec line is returned for the UI to surface',
        () async {
      // Contract anchor: the exec-type steer answer keeps its display text
      // end-to-end (home_screen snackbars exec-type dispatches already).
      final (gw, store) = await _open();
      gw.steerReply = {
        'type': 'exec',
        'output': '⏩ Steer queued — arrives after the next tool call: hi'
      };
      final d = await store.execSlashDispatch('/steer hi');
      expect(d.isExec, isTrue);
      expect(d.display, contains('Steer queued'));
    });

    test('idle steer: the "sent as next turn" notice is NOT swallowed',
        () async {
      final (gw, store) = await _open();
      final notices = <String>[];
      store.notices.listen(notices.add);
      gw.steerReply = {
        'type': 'send',
        'message': 'focus on X',
        'notice': 'No agent running; sent as next turn: focus on X',
      };
      final submittedBefore = gw.calls
          .where((c) => c.$1 == 'prompt.submit')
          .length; // resume doesn't submit
      await store.execSlashDispatch('/steer focus on X');
      expect(
          gw.calls
              .where((c) => c.$1 == 'prompt.submit')
              .length,
          greaterThan(submittedBefore),
          reason: 'the idle path still sends the message');
      expect(notices, contains(contains('sent as next turn')),
          reason: 'and the user is TOLD which path happened — that is what '
              'made /steer feel inconsistent: same command, silent feedback');
    });

    test('refused steer: bare send still submits without a phantom notice',
        () async {
      final (gw, store) = await _open();
      final notices = <String>[];
      store.notices.listen(notices.add);
      gw.steerReply = {'type': 'send', 'message': 'focus on X'};
      await store.execSlashDispatch('/steer focus on X');
      expect(gw.calls.where((c) => c.$1 == 'prompt.submit'), isNotEmpty);
      expect(notices, isEmpty,
          reason: 'nothing to report when the gateway reported nothing');
    });
  });

  group('/yolo verifies the session flag and tracks it per conversation', () {
    test('/yolo toggles via config.set and the banner follows the answer',
        () async {
      final (gw, store) = await _open();
      expect(store.yoloActive, isFalse);
      await store.execSlashDispatch('/yolo');
      // VERIFIED TARGET: the store must trust the config.set answer (and its
      // session.info echo), not a worker text output.
      final yoloSets = gw.calls
          .where((c) =>
              c.$1 == 'config.set' &&
              c.$2['key'] == 'yolo' &&
              c.$2['session_id'] == 'live-1')
          .toList();
      expect(yoloSets, isNotEmpty,
          reason: 'same verified RPC the desktop sends (setSessionYolo)');
      expect(store.yoloActive, isTrue);
      await store.execSlashDispatch('/yolo');
      expect(store.yoloActive, isFalse,
          reason: 'toggle OFF must be equally reliable');
    });

    test('/yolo reports its state to the user every time', () async {
      final (gw, store) = await _open();
      final notices = <String>[];
      store.notices.listen(notices.add);
      await store.execSlashDispatch('/yolo');
      expect(notices.join('\n').toLowerCase(), contains('yolo'),
          reason: 'the user needs to know which way it moved');
    });

    test('a conversation switch re-reads yolo from the resume info', () async {
      // Two stored keys, two runtime sids, two independent session flags.
      SharedPreferences.setMockInitialValues({});
      final gw = _TwoSessionGateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();

      await store.resumeSession('stored-1');
      expect(store.yoloActive, isTrue,
          reason: 'resume info carries the session yolo flag');
      await store.resumeSession('stored-2');
      expect(store.yoloActive, isFalse,
          reason: 'the second conversation has its OWN flag; showing the '
              'first conversation\'s banner is the inconsistency Angela hit');
      // And yolo commands after the switch must target the NEW session.
      await store.execSlashDispatch('/yolo');
      final sets = gw.calls
          .where((c) => c.$1 == 'config.set' && c.$2['key'] == 'yolo')
          .toList();
      expect(sets, isNotEmpty);
      expect(sets.last.$2['session_id'], 'live-2',
          reason: 'the toggle applies to the conversation on screen');
    });
  });
}

class _TwoSessionGateway extends GatewayClient {
  _TwoSessionGateway() : super(_cfg);
  final calls = <(String, Map<String, dynamic>)>[];
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final yoloFlags = {'stored-1': true, 'stored-2': false};

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => pushed.stream;
  @override
  Stream<GwConnectionState> get stateChanges => const Stream.empty();
  @override
  Future<void> connect({bool isReconnect = false}) async {}

  static String _sid(String stored) =>
      stored == 'stored-1' ? 'live-1' : 'live-2';

  @override
  Future<Map<String, dynamic>> request(String method,
      [Map<String, dynamic> params = const {}, int timeoutMs = 120000]) async {
    calls.add((method, params));
    return switch (method) {
      'session.resume' => {
          'session_id': _sid((params['session_id'] ?? '').toString()),
          'resumed': params['session_id'],
          'running': false,
          'info': {
            'model': 'm',
            'yolo': yoloFlags[params['session_id']] ?? false,
          },
          'messages': const <Map<String, dynamic>>[],
        },
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'session.active_list' => {
          'sessions': [
            {'id': 'live-1', 'session_key': 'stored-1'},
            {'id': 'live-2', 'session_key': 'stored-2'},
          ]
        },
      'config.set' => switch (params['key']) {
          'yolo' => {'value': '1', 'scope': 'session'},
          _ => {'value': ''},
        },
      'prompt.submit' => {'status': 'streaming'},
      'session.usage' => {'context_used': 1, 'context_max': 2},
      _ => <String, dynamic>{},
    };
  }

  @override
  Future<void> dispose() async {
    await pushed.close();
  }
}
