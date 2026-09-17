import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/diagnostics/error_report.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 19 (2026-09-14): the two device assertions when displaying a
/// conversation —
///   `object.dart`: 'child._parent == this' (RenderObject.dropChild), and
///   `framework.dart`: '_elements.contains(element)' (_InactiveElements.remove)
/// — both come from the element/render-tree bookkeeping family. The only path
/// that reaches `_InactiveElements.remove` is `_retakeInactiveElement`, which
/// runs only for a widget carrying a **GlobalKey**; inside the transcript the
/// only GlobalKey-bearing widgets are `SelectableText`s, whose inner
/// `EditableText` announces `wantKeepAlive` as soon as it gains focus
/// (`editable_text.dart`: `wantKeepAlive => widget.focusNode.hasFocus`).
/// A kept-alive child parked in a sliver's keep-alive bucket, in a list whose
/// itemCount changes on every streaming delta, is exactly that bookkeeping
/// path — so the transcript no longer uses automatic keep-alives.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class R19Gateway extends GatewayClient {
  R19Gateway() : super(_cfg);
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
    switch (method) {
      case 'session.resume':
        return {
          'session_id': 'live-b',
          'resumed': params['session_id'],
          'messages': List.generate(
              6,
              (i) => {
                    'role': i.isEven ? 'user' : 'assistant',
                    'text': i.isEven ? 'question $i' : 'answer $i with `code`',
                    'ts': i.toDouble(),
                  }),
          'info': {'model': 'test-model'},
        };
      case 'session.list':
        return {'sessions': const <Map<String, dynamic>>[]};
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

  group('transcript keep-alive hardening (round 19)', () {
    testWidgets('the transcript list does not use automatic keep-alives',
        (tester) async {
      tester.view.physicalSize = const Size(1260, 2700);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final gw = R19Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: HomeScreen(storeOverride: store))));
      await tester.pump();
      await store.resumeSession('stored-b');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      final lists = tester.widgetList<ListView>(find.byType(ListView));
      final transcript = lists.firstWhere((l) => l.reverse,
          orElse: () => throw StateError('no reversed transcript list'));
      final delegate = transcript.childrenDelegate;
      expect(delegate, isA<SliverChildBuilderDelegate>());
      expect((delegate as SliverChildBuilderDelegate).addAutomaticKeepAlives,
          isFalse,
          reason: 'a SelectableText that gains focus announces wantKeepAlive; '
              'keep-aliving it inside a list whose itemCount changes during '
              'streaming is the element/render-tree bookkeeping path that '
              'asserts (dropChild / _InactiveElements.remove)');
    });
  });

  group('copyable error report (round 19)', () {
    test('format() carries the exception and the recent log tail', () {
      ErrorReport.clearForTest();
      final details = FlutterErrorDetails(
        exception: StateError('transcript blew up'),
        stack: StackTrace.current,
        library: 'talaria test',
      );
      final text = ErrorReport.format(details);
      expect(text, contains('Talaria error report'));
      expect(text, contains('transcript blew up'));
      // The library name is upper-cased into the framework banner.
      expect(text.toUpperCase(), contains('TALARIA TEST'));
    });

    test('install() swaps the un-copyable red screen for the report panel',
        () {
      final previousBuilder = ErrorWidget.builder;
      final previousOnError = FlutterError.onError;
      addTearDown(() {
        ErrorWidget.builder = previousBuilder;
        FlutterError.onError = previousOnError;
      });

      ErrorReport.install();
      addTearDown(ErrorReport.uninstallForTest);

      final panel = ErrorWidget.builder(FlutterErrorDetails(
        exception: StateError('rendering failed'),
        stack: StackTrace.current,
      ));
      expect(panel, isA<ErrorReportPanel>());
    });

    testWidgets('the panel shows the report as copyable text with a button',
        (tester) async {
      final details = FlutterErrorDetails(
        exception: StateError('cannot lay out'),
        stack: StackTrace.current,
      );
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: ErrorReportPanel(details: details))));

      expect(find.byType(SelectableText), findsOneWidget,
          reason: 'the report must be selectable (long-press copyable) even '
              'if the clipboard button fails');
      expect(find.text('Copy report'), findsOneWidget);
      final shown = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(shown.data, contains('cannot lay out'));
    });

    test('captured errors land in ErrorReport.last', () async {
      ErrorReport.clearForTest();
      final previousOnError = FlutterError.onError;
      addTearDown(() => FlutterError.onError = previousOnError);
      ErrorReport.install();
      addTearDown(ErrorReport.uninstallForTest);
      FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('captured for the report'),
        stack: StackTrace.current,
      ));
      expect(ErrorReport.last.value, contains('captured for the report'));
    });
  });
}
