import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 61: a response must never throw the reader to the top of the
/// conversation.
///
/// Angela, on 1.4.2 / build 59: "every time a response is received in a chat,
/// the conversation scrolls all the way to the top ... if they come in rapidly
/// I can't stay scrolled to the bottom."
///
/// MEASURED on the build 59 code with this fixture: a reader parked 360px
/// above the newest end, the second turn's history merge raising the extent
/// ESTIMATE from 61392.3 to 175759.0. The epoch branch compensated with that
/// phantom delta, `target = 360.0 + 114366.7 = 114726.7`, and the reader
/// landed on `question 0`, the oldest message.
///
/// The cause is that the epoch (replaced-transcript) branch still trusted
/// maxScrollExtent, which this same file's streaming hold had already stopped
/// trusting because it is an ESTIMATE in a lazy variable-height list. Its
/// out-of-range guard could not refuse the move: target - max == ref - refMax,
/// so an in-range reference always produced an in-range target. "Once per
/// epoch" bounded how often it fired, never how far.
///
/// The rule now: ONE measured hold for both cases. The anchor is the oldest
/// row visibly on screen; compensate by exactly how far that row actually
/// moved; no anchor, no move. Nothing in the transcript path reads
/// maxScrollExtent as content growth any more.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class SGateway extends GatewayClient {
  SGateway() : super(_cfg);
  final pushed = StreamController<GatewayEvent>.broadcast(sync: true);
  Map<String, dynamic> resumeReply = const {};
  List<Map<String, dynamic>> historyRows = const [];

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
    return switch (method) {
      'session.resume' => resumeReply,
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'session.active_list' => {
          'sessions': [
            {'id': 'live-r61', 'session_key': 'stored-r61'}
          ]
        },
      'prompt.submit' => {'status': 'streaming'},
      'session.history' => {'messages': historyRows},
      'session.usage' => {'context_used': 1, 'context_max': 2},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data,
          {String sid = 'live-r61'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
  }
}

List<Map<String, dynamic>> _history(int pairs) {
  String body(String tag, int i) =>
      '$tag $i\n${List.generate(8, (j) => '$tag-$i line $j: the quick brown fox jumps over the lazy dog and keeps going for a while').join('\n')}';
  final rows = <Map<String, dynamic>>[];
  var ts = 1.0;
  for (var i = 0; i < pairs; i++) {
    rows.add({'role': 'user', 'text': body('question', i), 'ts': ts++});
    rows.add({'role': 'assistant', 'text': body('answer', i), 'ts': ts++});
  }
  return rows;
}

final replyText = [
  "FULL REPLY line 000: the agent's final answer in markdown, long enough to "
      'be several hundred logical pixels tall once laid out.',
  ...List.generate(
      45,
      (i) => 'FULL REPLY paragraph line ${i.toString().padLeft(3, '0')}: '
          'more prose prose prose prose prose prose prose prose prose.'),
].join('\n');

ScrollPosition _transcript(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView).first).controller!.position;

/// The uppermost glyph line the reader can actually see, identified by its
/// history label (`answer-17 line 3`, `FULL REPLY paragraph line 012`, ...).
/// A row-identity-free way to ask "is the reader still looking at the same
/// thing?": the string is what is on screen, not a scroll number.
String _oldestVisibleLine(WidgetTester tester) {
  final viewport = tester.getRect(find.byType(ListView).first);
  final idPattern = RegExp(r'(answer|question)[-\s](\d+)');
  String? result;
  var bestY = double.infinity;
  var bestFull = double.infinity;
  for (final element in find.byType(RichText).evaluate()) {
    final paragraph = element.renderObject;
    if (paragraph is! RenderParagraph) continue;
    final text = (element.widget as RichText).text.toPlainText();
    if (!text.contains('line ') && !text.contains('Sealed interim')) continue;
    final origin = paragraph.localToGlobal(Offset.zero);
    var offset = 0;
    for (final line in text.split('\n')) {
      final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: offset, extentOffset: offset + line.length));
      for (final box in boxes) {
        final y = origin.dy + box.top;
        if (origin.dy + box.bottom <= viewport.top || y >= viewport.bottom) {
          continue;
        }
        final m = idPattern.firstMatch(line);
        if (m != null && y < bestY) {
          bestY = y;
          result = '${m.group(1)}-${m.group(2)}';
        }
        if (line.startsWith('FULL REPLY') && y < bestFull) {
          bestFull = y;
        }
      }
      offset += line.length + 1;
    }
  }
  if (result != null) return result;
  if (bestFull < double.infinity) return 'FULL REPLY';
  return '<none>';
}

Future<void> _fingerDrag(WidgetTester tester, int steps, double dy) async {
  final rect = tester.getRect(find.byType(ListView).first);
  // Start in the list's own padding: a SelectableText row would claim the
  // gesture and the drag would not scroll at all.
  final gesture =
      await tester.startGesture(Offset(rect.left + 3, rect.top + 50));
  for (var step = 0; step < steps; step++) {
    await gesture.moveBy(Offset(0, dy));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 500));
}

/// One realistic turn: trace, tool, an INTERIM seal (which is what makes the
/// durable history diverge in shape from the live transcript), the full text
/// reply, then the deferred authoritative history merge.
Future<void> _turn(WidgetTester tester, SGateway gw, ChatStore store,
    List<Map<String, dynamic>> history, int turn) async {
  await store.send('a question $turn');
  await tester.pump();
  for (final event in <MapEntry<String, Map<String, dynamic>>>[
    MapEntry('message.start', <String, dynamic>{}),
    MapEntry('thinking.delta', {
      'text': List.generate(
              30, (i) => 'thinking thought line $i about the situation')
          .join('\n')
    }),
    MapEntry('tool.start', {'name': 'terminal', 'tool_id': 't$turn'}),
    MapEntry('tool.complete',
        {'name': 'terminal', 'tool_id': 't$turn', 'output': 'ok'}),
    MapEntry('message.interim',
        {'text': 'Sealed interim sentence.\n', 'already_streamed': false}),
    MapEntry('message.delta', {'text': replyText}),
    MapEntry('message.complete', {'text': replyText, 'status': 'complete'}),
  ]) {
    gw.emit(event.key, event.value);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
  }
  expect(store.messages.last.text, replyText,
      reason: 'the wire key for message.complete is `text`; a fake using '
          '`final_response` leaves the row EMPTY and measures nothing');

  history.addAll([
    {'role': 'user', 'text': 'a question $turn', 'ts': 100.0 + turn * 2},
    {'role': 'assistant', 'text': replyText, 'ts': 101.0 + turn * 2},
  ]);
  gw.historyRows = List.of(history);
  final beforeEpoch = store.transcriptEpoch;
  gw.emit('sessions.changed', {});
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 80));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1000));
  await tester.pump();
  expect(store.transcriptEpoch, greaterThan(beforeEpoch),
      reason: 'the fixture must exercise the epoch/replacement path, or it '
          'proves nothing');
  expect(tester.takeException(), isNull);
}

Future<ChatStore> _open(WidgetTester tester, SGateway gw,
    List<Map<String, dynamic>> history) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1260, 2700);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  gw.resumeReply = {
    'session_id': 'live-r61',
    'resumed': 'stored-r61',
    'messages': history,
  };
  gw.historyRows = List.of(history);
  final store = ChatStore(config: _cfg, client: gw);
  addTearDown(store.dispose);
  await store.connect();
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
  await tester.pump();
  await store.resumeSession('stored-r61');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a reader parked just above the newest end is not thrown to the '
      'top of the conversation by a response', (tester) async {
    final gw = SGateway();
    final history = _history(15);
    final store = await _open(tester, gw, history);

    await _fingerDrag(tester, 15, 12);
    final parked = _transcript(tester).pixels;
    expect(parked, greaterThan(48), reason: 'the reader is parked (latch off)');
    expect(parked, lessThan(400),
        reason: 'parked just above the newest rows, looks pinned at the '
            'bottom, exactly the state Angela reads in');

    for (var turn = 1; turn <= 3; turn++) {
      await _turn(tester, gw, store, history, turn);
      final pos = _transcript(tester);
      final anchor = _oldestVisibleLine(tester);
      // ignore: avoid_print
      print('R61[near turn=$turn] pixels=${pos.pixels.toStringAsFixed(1)} '
          'max=${pos.maxScrollExtent.toStringAsFixed(1)} anchor=$anchor');
      expect(pos.pixels, greaterThanOrEqualTo(0),
          reason: 'a negative offset is plumbing, never a position');
      expect(pos.pixels, lessThan(4000),
          reason: 'turn $turn flung the reader to '
              '${pos.pixels.toStringAsFixed(1)} of '
              '${pos.maxScrollExtent.toStringAsFixed(1)}, that is the OLDEST '
              'end of the conversation (measured on build 59: 114726.7, '
              'anchor=question 0). Only real, measured movement of the row on '
              'screen may move the reader.');
      expect(anchor, isNot(contains('question 0')),
          reason: 'the reader ended the turn looking at the first message of '
              'the conversation');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a PURE APPEND from another client keeps the reader on their line',
      (tester) async {
    // The cross-client case: the durable history grows by rows the live
    // transcript does not have. Every existing row keeps its identity, so this
    // is GROWTH, not a replacement - the view can still measure it, and the
    // reader's line must stay put. (The store must therefore not bump the
    // transcript epoch for an append-only merge: that bump tells the view
    // "the rows under you changed", which is false here.)
    final gw = SGateway();
    final history = _history(20);
    final store = await _open(tester, gw, history);

    for (var swipe = 0;
        swipe < 60 &&
            _transcript(tester).pixels <
                _transcript(tester).maxScrollExtent * 0.40;
        swipe++) {
      await _fingerDrag(tester, 30, 14);
    }
    final anchorBefore = _oldestVisibleLine(tester);
    expect(anchorBefore, isNot('<none>'));
    final pixelsBefore = _transcript(tester).pixels;
    final epochBefore = store.transcriptEpoch;

    history.addAll([
      {'role': 'user', 'text': 'from another client', 'ts': 500.0},
      {'role': 'assistant', 'text': 'and its answer', 'ts': 501.0},
    ]);
    gw.historyRows = List.of(history);
    gw.emit('sessions.changed', {});
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    final pos = _transcript(tester);
    // ignore: avoid_print
    print('R61[append] pixels=${pos.pixels.toStringAsFixed(1)} '
        'before=${pixelsBefore.toStringAsFixed(1)} anchor=${_oldestVisibleLine(tester)}');
    expect(store.transcriptEpoch, epochBefore,
        reason: 'an append-only merge must not report a replaced transcript');
    expect(store.messages.length, history.length,
        reason: 'the append must have landed, or this proves nothing');
    expect(_oldestVisibleLine(tester), anchorBefore,
        reason: 'the reader must still be looking at the same message');
    expect(pos.pixels, greaterThan(pixelsBefore - 60),
        reason: 'the offset follows real appended growth, never backwards');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a reader parked mid-conversation keeps the same line on screen '
      'across four streamed responses', (tester) async {
    final gw = SGateway();
    final history = _history(30);
    final store = await _open(tester, gw, history);

    for (var swipe = 0;
        swipe < 60 &&
            _transcript(tester).pixels <
                _transcript(tester).maxScrollExtent * 0.40;
        swipe++) {
      await _fingerDrag(tester, 30, 14);
    }
    final mid = _transcript(tester).pixels;
    expect(mid, greaterThan(_transcript(tester).maxScrollExtent * 0.35));
    final anchorBefore = _oldestVisibleLine(tester);
    expect(anchorBefore, isNot('<none>'),
        reason: 'the fixture must resolve a real visible row');

    for (var turn = 1; turn <= 4; turn++) {
      await _turn(tester, gw, store, history, turn);
      final pos = _transcript(tester);
      final anchor = _oldestVisibleLine(tester);
      // ignore: avoid_print
      print('R61[mid turn=$turn] pixels=${pos.pixels.toStringAsFixed(1)} '
          'max=${pos.maxScrollExtent.toStringAsFixed(1)} anchor=$anchor');
      expect(pos.pixels, greaterThanOrEqualTo(0));
      expect(pos.pixels, lessThan(pos.maxScrollExtent),
          reason: 'the reader must not be moved to either end');
      expect(anchor, anchorBefore,
          reason: 'turn $turn moved the line the reader was on: their place '
              'in the conversation must not drift while they read');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
