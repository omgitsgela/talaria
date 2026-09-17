import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talaria/src/diagnostics/error_report.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Fake gateway for the round-29 work: cold-start behaviour, in-flight history
/// reads, and the roster filter.
class R29Gateway extends GatewayClient {
  R29Gateway({this.listRows = const []})
      : super(GatewayConfig(url: 'http://gw.example.internal:9119'));

  List<Map<String, dynamic>> listRows;

  /// When set, `session.history` waits on it, which keeps a history read in
  /// flight for as long as the test wants.
  Completer<void>? historyGate;

  /// Rows `session.resume` reports.
  List<Map<String, dynamic>> resumeRows = const [];

  final _pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  final _stateCtl = StreamController<GwConnectionState>.broadcast(sync: true);

  @override
  GwConnectionState get state => GwConnectionState.open;
  @override
  Stream<GatewayEvent> get events => _pushed.stream;
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
      case 'session.resume':
        return {
          'session_id': 'rt-1',
          'resumed': params['session_id'],
          'messages': resumeRows,
          // A truthful count with no rows is the shape that arms the deferred
          // history pull (the live record is still hydrating).
          'message_count': resumeRows.isEmpty ? 12 : resumeRows.length,
          'running': false,
          'info': {'model': 'test-model'},
        };
      case 'session.history':
        final gate = historyGate;
        if (gate != null) await gate.future;
        return {'messages': const <Map<String, dynamic>>[]};
      case 'session.list':
        return {'sessions': listRows};
      case 'session.active_list':
        return {
          'sessions': [
            {'id': 'rt-1', 'session_id': 'rt-1'}
          ]
        };
      case 'session.create':
        return {'session_id': 'rt-draft', 'session_key': 'stored-draft'};
      case 'session.usage':
        return {'context_used': 1000, 'context_max': 128000, 'context_percent': 1};
      case 'config.get':
        return {'value': 'test-model'};
      case 'slash.exec':
        return {'output': 'No active goal. Set one with /goal <text>.'};
      default:
        return {};
    }
  }

  void emit(String type, Map<String, dynamic> data, {String sid = 'rt-1'}) =>
      _pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await _pushed.close();
    await _stateCtl.close();
  }
}

final _cfg = GatewayConfig(url: 'http://gw.example.internal:9119');

Future<ChatStore> _open(R29Gateway gw) async {
  final store = ChatStore(config: _cfg, client: gw);
  await store.connect();
  return store;
}

Widget _themed(Widget child) => MaterialApp(home: child);

void _phoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1260, 2700);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

double _nowSeconds() => DateTime.now().millisecondsSinceEpoch / 1000.0;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('cold start after a force close', () {
    test('a pending refresh is not evidence that something is loading',
        () async {
      final gw = R29Gateway();
      final store = await _open(gw);
      addTearDown(store.dispose);

      // The gateway broadcasts as soon as a client attaches. With no
      // conversation open there is nothing to load, and the refresh intent is
      // deliberately left armed for later — which is exactly why it must not be
      // read as "a load is in progress".
      gw.emit('sessions.changed', const {});
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(store.loadingSession, isFalse);
      expect(store.awaitingTranscript, isFalse,
          reason: 'this is what left the app stuck on Loading conversation… '
              'after a force close and reopen');
    });

    testWidgets('the view shows the new-chat empty state, not a spinner',
        (tester) async {
      _phoneSurface(tester);
      final gw = R29Gateway();
      final store = await _open(gw);
      addTearDown(store.dispose);
      gw.emit('sessions.changed', const {});

      await tester.pumpWidget(
          _themed(Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump(const Duration(milliseconds: 60));
      // Let the debounced refresh timer fire so no timer outlives the test.
      await tester.pump(const Duration(milliseconds: 800));

      expect(find.text('Loading conversation…'), findsNothing);
      expect(find.text('Ask Hermes anything'), findsOneWidget);
    });
  });

  group('loading state', () {
    test('an in-flight history read counts as loading, and clears', () async {
      final gw = R29Gateway()..historyGate = Completer<void>();
      final store = await _open(gw);
      addTearDown(store.dispose);

      // A resume that reports no rows arms the deferred read: the transcript is
      // still on its way, so the view must not claim the conversation is new.
      await store.resumeSession('stored-1');
      expect(store.messages, isEmpty);
      // The deferred read fires on its 750ms debounce.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(store.awaitingTranscript, isTrue,
          reason: 'a history read really is in flight');

      gw.historyGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(store.awaitingTranscript, isFalse,
          reason: 'in-flight work is bounded, so the state cannot outlive it');
    });
  });

  group('conversation search', () {
    testWidgets('filters on title and preview, and cannot dead-end',
        (tester) async {
      _phoneSurface(tester);
      final gw = R29Gateway()
        ..listRows = [
          {
            'id': 's1',
            'title': 'Brake pad measurements',
            'preview': 'caliper depth notes',
            'started_at': _nowSeconds(),
            'message_count': 12,
          },
          {
            'id': 's2',
            'title': 'Session notes',
            'preview': 'wind was strong on leg 3',
            'started_at': _nowSeconds(),
            'message_count': 40,
          },
        ];
      final store = await _open(gw);
      addTearDown(store.dispose);
      await store.loadSessions();

      await tester.pumpWidget(_themed(SessionsSheet(store: store)));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('Brake pad measurements'), findsOneWidget);
      expect(find.text('Session notes'), findsOneWidget);

      final field = find.widgetWithText(TextField, 'Search conversations…');
      expect(field, findsOneWidget);
      await tester.enterText(field, 'brake');
      await tester.pump();
      expect(find.text('Brake pad measurements'), findsOneWidget);
      expect(find.text('Session notes'), findsNothing);

      // A preview match is what people usually remember.
      await tester.enterText(field, 'wind');
      await tester.pump();
      expect(find.text('Session notes'), findsOneWidget);
      expect(find.text('Brake pad measurements'), findsNothing);

      // No match must keep the field and offer a way back to the full list.
      await tester.enterText(field, 'zzz-nothing');
      await tester.pump();
      expect(find.text('No conversations match “zzz-nothing”.'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget,
          reason: 'the filter must not remove the control that undoes it');

      await tester.tap(find.text('Clear search'));
      await tester.pump();
      expect(find.text('Brake pad measurements'), findsOneWidget);
      expect(find.text('Session notes'), findsOneWidget);
    });
  });

  group('bug report bundle', () {
    test('carries the facts, never a token, and says when nothing was caught',
        () {
      ErrorReport.clearForTest();
      final text = ErrorReport.bugReport({
        'app': 'v1.9.9 (build 99)',
        'platform': 'android',
        'gateway host': 'gw.example.internal',
      });
      expect(text, contains('Talaria bug report'));
      expect(text, contains('v1.9.9 (build 99)'));
      expect(text, contains('gw.example.internal'));
      expect(text, contains('none captured in this session'));
      expect(text.toLowerCase(), isNot(contains('token')));
    });

    test('embeds a captured error when there is one', () {
      ErrorReport.clearForTest();
      ErrorReport.last.value = 'EXCEPTION CAUGHT: render tree assertion';
      final text = ErrorReport.bugReport({'app': 'v1.9.9 (build 99)'});
      expect(text, contains('render tree assertion'));
      expect(text, isNot(contains('none captured in this session')));
      ErrorReport.clearForTest();
    });

    testWidgets('the error panel renders the report with a copy action',
        (tester) async {
      final details = FlutterErrorDetails(exception: StateError('boom'));
      await tester.pumpWidget(_themed(ErrorReportPanel(details: details)));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.textContaining('Copy the report'), findsOneWidget);
      expect(find.text('Copy report'), findsOneWidget);
      expect(find.textContaining('boom'), findsWidgets);
    });

    test('install is active in every build, not just debug', () async {
      // The release path is the whole point of the feature, and it is the one
      // the test VM cannot exercise: kDebugMode is always true here. What is
      // verifiable is that install() no longer gates on it, and that its
      // framework wiring is in place after calling it.
      ErrorReport.install();
      addTearDown(ErrorReport.uninstallForTest);
      expect(ErrorWidget.builder(FlutterErrorDetails(exception: 'x')),
          isA<ErrorReportPanel>());
    });
  });
}
