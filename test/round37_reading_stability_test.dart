import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Two reports from reading earlier in a conversation while a turn streams:
///
/// 1. "reasoning traces you're currently reading earlier in the conversation
///    auto collapse when new content is streaming in."
/// 2. "every new line generated in a thinking trace causes the screen to jitter
///    up and down, probably as it's adjusting to the total size of the
///    conversation view and then moving back down."
///
/// (1) was an identity failure in the reversed list. The rows carried a key on
/// the MessageBubble, but the builder returned a wrapper Column, and a SLIVER
/// matches children by the key of the widget it is handed (wrapped in a salted
/// KeyedSubtree). With no key at that level, every index shift - and appending a
/// message shifts every index, since `i = count - 1 - v` - re-created the whole
/// visible list, dropping each row's State with it. That is why an expanded
/// trace snapped shut the moment a new message started.
///
/// (2) was per-character layout churn: every streamed character grew the newest
/// end, the layout shifted, and the read-hold's POST-layout compensation moved it
/// back, two phases per character. While the reader is away from the newest end
/// those characters are off-screen anyway, so the store now defers them and
/// repaints once when the reader returns.

final _cfg = GatewayConfig(url: 'http://localhost:1');

class R37Gateway extends GatewayClient {
  R37Gateway() : super(_cfg);
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
      'session.create' => {'session_id': 'live-a'},
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'prompt.submit' => {'status': 'streaming'},
      'session.usage' => {'context_used': 1000, 'context_max': 128000},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data, {String sid = 'live-b'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
    await _stateCtl.close();
  }
}

ScrollPosition _pos(WidgetTester tester) {
  final lv = tester.widget<ListView>(find.byType(ListView).first);
  final c = lv.controller;
  if (c != null && c.hasClients) return c.position;
  throw StateError('no transcript');
}

/// Four older exchanges, then the message that carries a long trace, then a few
/// more, so there is somewhere to read above and below.
List<Map<String, dynamic>> _fixture() {
  final rows = <Map<String, dynamic>>[];
  var ts = 1.0;
  for (var i = 0; i < 4; i++) {
    rows.add({'role': 'user', 'text': 'older question $i', 'ts': ts++});
    rows.add({'role': 'assistant', 'text': 'older answer $i', 'ts': ts++});
  }
  rows.add({'role': 'user', 'text': 'the question with the trace', 'ts': ts++});
  rows.add({
    'role': 'assistant',
    'text': 'TRACE-ANSWER-BODY',
    'reasoning': List.generate(
            10, (i) => 'TRACE-SENTENCE-$i reasoning content, a long line.')
        .join('\n\n'),
    'ts': ts++,
  });
  for (var i = 0; i < 3; i++) {
    rows.add({'role': 'user', 'text': 'later question $i', 'ts': ts++});
    rows.add({'role': 'assistant', 'text': 'later answer $i', 'ts': ts++});
  }
  return rows;
}

Future<(R37Gateway, ChatStore)> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1260, 2700);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final gw = R37Gateway();
  gw.responses['session.resume'] = {
    'session_id': 'live-b',
    'resumed': 'stored-b',
    'messages': _fixture(),
  };
  final store = ChatStore(config: _cfg, client: gw);
  addTearDown(store.dispose);
  await store.connect();
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
  await tester.pump();
  await store.resumeSession('stored-b');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
  return (gw, store);
}

/// The trace's text is rendered only while its tile is EXPANDED.
int _traceExpanded(WidgetTester tester) =>
    find.textContaining('TRACE-SENTENCE-0').evaluate().length;

/// Fixed pumps instead of `pumpAndSettle`: a streaming turn keeps a spinner
/// animating forever, so pumpAndSettle times out.
Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 80));
}

/// A reader drag from the transcript's own padding (points over selectable text
/// can be claimed by the text and never scroll).
Future<void> _dragUp(WidgetTester tester, double by) async {
  final g = await tester.startGesture(
      tester.getTopLeft(find.byType(ListView).first) + const Offset(10, 6));
  for (var i = 0; i < (by / 30).ceil(); i++) {
    await g.moveBy(Offset(0, by / (by / 30).ceil()));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reading earlier while content streams', () {
    testWidgets('an expanded trace does not collapse when new content arrives',
        (tester) async {
      final (gw, _) = await _open(tester);

      await _dragUp(tester, 240);
      expect(find.text('Reasoning'), findsOneWidget,
          reason: 'the trace message is on screen to read');
      await tester.tap(find.text('Reasoning'));
      await tester.pumpAndSettle();
      expect(_traceExpanded(tester), 1, reason: 'the trace is open');

      // A new turn starts and streams: appending a message shifts every builder
      // index in the reversed list.
      gw.emit('message.start', {'message_id': 'new-1'});
      await tester.pump(const Duration(milliseconds: 16));
      expect(_traceExpanded(tester), 1,
          reason: 'opening a new message must NOT collapse a trace the reader '
              'has open (row identity failed here before)');

      for (var i = 0; i < 15; i++) {
        gw.emit('reasoning.delta', {'text': 'NEW-STREAM-CHUNK-$i. '});
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_traceExpanded(tester), 1,
          reason: 'streamed characters must not collapse it either');
    });

    testWidgets('streamed characters do not churn the layout under the reader',
        (tester) async {
      final (gw, _) = await _open(tester);
      final p = _pos(tester);

      await _dragUp(tester, 240);
      gw.emit('message.start', {'message_id': 'new-1'});
      await tester.pump(const Duration(milliseconds: 16));
      await _settle(tester);
      final anchorPixels = p.pixels;
      final anchorMax = p.maxScrollExtent;
      expect(anchorPixels, greaterThan(48), reason: 'the reader is scrolled up');

      for (var i = 0; i < 12; i++) {
        gw.emit('reasoning.delta', {'text': 'NEW-STREAM-CHUNK-$i. '});
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(p.maxScrollExtent, anchorMax,
          reason: 'a streamed character must not re-lay-out the transcript '
              'under a reader who is away from the newest end: each growth '
              'shifts the content and the compensation moves it back, which is '
              'the reported up/down jitter');
      expect(p.pixels, anchorPixels,
          reason: 'the reading position must not move at all');
    });

    testWidgets('returning to the newest end paints everything that was deferred',
        (tester) async {
      final (gw, _) = await _open(tester);
      final p = _pos(tester);
      await _dragUp(tester, 240);
      gw.emit('message.start', {'message_id': 'new-1'});
      await tester.pump(const Duration(milliseconds: 16));
      await _settle(tester);

      for (var i = 0; i < 12; i++) {
        gw.emit('reasoning.delta', {'text': 'NEW-STREAM-CHUNK-$i. '});
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.textContaining('NEW-STREAM-CHUNK-11').evaluate().length, 0,
          reason: 'the deferral means it is not painted while reading');

      // The jump-to-latest arrow is the documented way back.
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_downward));
      await _settle(tester);

      expect(p.pixels, lessThan(1), reason: 'the arrow returns to the newest end');
      expect(find.textContaining('NEW-STREAM-CHUNK-11').evaluate().length, 1,
          reason: 'the accumulated stream must be painted on return, so the '
              'reader never comes back to a frozen transcript');
    });

    testWidgets('a structural event still repaints while reading', (tester) async {
      final (gw, _) = await _open(tester);
      final p = _pos(tester);
      await _dragUp(tester, 240);
      final before = p.maxScrollExtent;

      // A tool starting is structural: it must not be deferred.
      gw.emit('message.start', {'message_id': 'new-1'});
      await tester.pump(const Duration(milliseconds: 16));
      await _settle(tester);
      gw.emit('tool.start',
          {'tool_id': 't1', 'name': 'shell', 'state': 'running', 'input': 'ls'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(p.maxScrollExtent, greaterThan(before),
          reason: 'a new tool chip is a structural change and must still be '
              'painted for a reader who is scrolled up');
    });
  });
}
