import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/screens/home_screen.dart';
import 'package:talaria/src/store/chat_store.dart';

/// Round 60 regression: a reader parked just above the newest rows (the
/// "looks pinned at the bottom" state) must NOT be flung up the conversation
/// when a full turn text reply lands ("any time a full text reply is sent to
/// the client, it scrolls to the very top", Angela's 1.4.1 report).
///
/// The reversed transcript list makes `maxScrollExtent` an ESTIMATE that
/// churns as tall new rows enter the build set. The read-hold used to treat
/// that churn as growth at the newest end and jumped the reader by it — twice
/// in one pass — landing them at the OLDEST message. The hold must instead
/// measure the real height change of the NEWEST row and compensate by exactly
/// that, once.
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
            {'id': 'live-r60', 'session_key': 'stored-r60'}
          ]
        },
      'prompt.submit' => {'status': 'streaming'},
      'session.history' => {'messages': historyRows},
      'session.usage' => {'context_used': 1, 'context_max': 2},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data,
          {String sid = 'live-r60'}) =>
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

ScrollPosition _transcript(WidgetTester tester) {
  final lv = tester.widget<ListView>(find.byType(ListView).first);
  return lv.controller!.position;
}

/// The oldest history line with glyph boxes inside the viewport band —
/// "what the reader is looking at", independent of any scroll numbers.
String? anchorLine(WidgetTester tester) {
  String? best;
  for (final e in find.byType(RichText).evaluate()) {
    final w = e.widget;
    if (w is! RichText) continue;
    final plain = w.text.toPlainText();
    if (!plain.contains('line ')) continue;
    final ro = e.renderObject;
    if (ro is! RenderParagraph) continue;
    final off = ro.localToGlobal(Offset.zero);
    for (final m in plain.split('\n')) {
      if (!m.contains('question') && !m.contains('answer')) continue;
      final idx = plain.indexOf(m);
      final boxes = ro.getBoxesForSelection(
          TextSelection(baseOffset: idx, extentOffset: idx + 12));
      for (final b in boxes) {
        final top = off.dy + b.top, bottom = off.dy + b.bottom;
        if (bottom > 70 && top < 780) {
          if (best == null || m.compareTo(best) < 0) best = m;
        }
      }
    }
  }
  return best;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a parked reader stays parked when a full reply lands',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1260, 2700);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final gw = SGateway();
    gw.resumeReply = {
      'session_id': 'live-r60',
      'resumed': 'stored-r60',
      'messages': _history(15),
    };
    gw.historyRows = _history(15);
    final store = ChatStore(config: _cfg, client: gw);
    addTearDown(store.dispose);
    await store.connect();
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: HomeScreen(storeOverride: store))));
    await tester.pump();
    await store.resumeSession('stored-r60');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // Park just above the newest rows with a real interleaved finger drag
    // (a programmatic jumpTo would arm a different path — see the contract).
    final lv = find.byType(ListView).first;
    final g = await tester.startGesture(tester.getCenter(lv));
    for (var s = 0; s < 15; s++) {
      await g.moveBy(const Offset(0, 12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 500));

    final parked = _transcript(tester).pixels;
    expect(parked, greaterThan(48), reason: 'reader is parked (latch off)');
    expect(parked, lessThan(400),
        reason: 'parked just above the newest rows — looks pinned');
    final seenBefore = anchorLine(tester);
    expect(seenBefore, isNotNull);

    // A realistic full turn: trace, tool, sealed sentence, FULL TEXT reply.
    await store.send('a question');
    gw.emit('message.start', {});
    gw.emit('thinking.delta', {
      'text': List.generate(30,
              (i) => 'thinking thought line $i about the situation and options')
          .join('\n')
    });
    await tester.pump(const Duration(milliseconds: 60));
    gw.emit('tool.start', {'name': 'terminal', 'tool_id': 't1'});
    await tester.pump(const Duration(milliseconds: 60));
    gw.emit('tool.complete', {
      'name': 'terminal',
      'tool_id': 't1',
      'output': 'ok'
    });
    gw.emit('message.interim',
        {'text': 'Sealed interim sentence.\n', 'already_streamed': false});
    gw.emit('message.delta', {'text': replyText});
    await tester.pump(const Duration(milliseconds: 60));
    gw.emit('message.complete', {'text': replyText, 'status': 'complete'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    final pos = _transcript(tester);
    // ignore: avoid_print
    print('R60[complete] pixels=${pos.pixels.toStringAsFixed(1)} '
        'max=${pos.maxScrollExtent.toStringAsFixed(1)}');
    // The reply's real height is a few thousand px. The old estimate-churn
    // fling put the reader 20k-40k up (the oldest message): clamp both.
    expect(pos.pixels, greaterThanOrEqualTo(0),
        reason: 'must never be dragged to a negative offset');
    expect(pos.pixels, lessThan(4000),
        reason: 'compensation must be bounded by the real growth at the '
            'newest end, not the extent ESTIMATE (was 40444 in the measured '
            'bug: reader flung to the oldest message).');

    // The deferred authoritative history merge rewrites the rows.
    gw.historyRows = [
      ..._history(15),
      {'role': 'user', 'text': 'a question', 'ts': 100.0},
      {'role': 'assistant', 'text': replyText, 'ts': 101.0}
    ];
    gw.emit('sessions.changed', {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 80));

    final pos2 = _transcript(tester);
    // ignore: avoid_print
    print('R60[merge] pixels=${pos2.pixels.toStringAsFixed(1)} '
        'max=${pos2.maxScrollExtent.toStringAsFixed(1)} '
        'anchor=${anchorLine(tester)}');
    expect(pos2.pixels, lessThan(4000),
        reason: 'the history merge must not re-fling the reader either');
    expect(pos2.pixels, greaterThanOrEqualTo(0));
  });
}
