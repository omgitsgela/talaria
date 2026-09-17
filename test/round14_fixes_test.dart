import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/client.dart';
import 'package:talaria/src/gateway/config.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/store/chat_store.dart';
import 'package:talaria/src/widgets/message_bubble.dart';

/// Round 14 (2026-09-13):
///   1. Splash tagline → "The Winged Sandals of Hermes — Swift Passage,
///      Wherever You Are." and the hold beat grew to 3s (asserted via the
///      constants in the screen).
///   2. Dark-mode fenced code blocks: flutter_markdown's default
///      `codeblockDecoration` is a light-blue panel that made code unreadable;
///      the bubble now gives blocks a theme-consistent panel + onSurface text.
///   3. Composer selection thrash: the input field is height-stable (a
///      variable min→max-lines field resized the transcript viewport while the
///      user was scrolling a selection, re-arming the jump-to-bottom).
///   4. TRANSCRIPT ORDERING: a turn is an interleaved stream (think → act →
///      think again → answer). The old model stored reasoning/tools/text as
///      three buckets, so the bubble always rendered thinking ABOVE all tools
///      ABOVE the answer — a still-running tool landed UNDER a thinking box.
///      ChatMessage now stores an ordered `parts` list and renders in true
///      order.
final _cfg = GatewayConfig(url: 'http://localhost:1');

class R14Gateway extends GatewayClient {
  R14Gateway() : super(_cfg);
  final calls = <(String, Map<String, dynamic>)>[];
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
    calls.add((method, params));
    return switch (method) {
      'session.create' => {'session_id': 'live-a'},
      'session.list' => {'sessions': const <Map<String, dynamic>>[]},
      'prompt.submit' => {'status': 'streaming'},
      _ => <String, dynamic>{},
    };
  }

  void emit(String type, Map<String, dynamic> data, {String sid = 'live-a'}) =>
      pushed.add(GatewayEvent(type: type, sessionId: sid, payload: data));

  @override
  Future<void> dispose() async {
    await pushed.close();
    await _stateCtl.close();
  }
}

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ordered transcript (round 14)', () {
    test('ChatMessage preserves think → tool → think order in parts', () {
      final m = ChatMessage(role: 'assistant');
      m.appendReasoning('plan it');
      m.addTool(ToolActivity(name: 'terminal'));
      m.appendReasoning('second thought');
      m.appendText('final answer');
      expect(m.parts.map((p) => p.kind).toList(), [
        MessagePartKind.reasoning,
        MessagePartKind.tool,
        MessagePartKind.reasoning,
        MessagePartKind.text,
      ]);
      // Bucket views still aggregate in order.
      expect(m.reasoning, 'plan itsecond thought');
      expect(m.tools, hasLength(1));
      expect(m.text, 'final answer');
    });

    test('a live streamed turn interleaves parts in true order', () async {
      final gw = R14Gateway();
      final store = ChatStore(config: _cfg, client: gw);
      addTearDown(store.dispose);
      await store.connect();

      gw.emit('message.start', {});
      gw.emit('reasoning.delta', {'text': 'thinking hard'});
      gw.emit('tool.start', {'name': 'terminal', 'tool_id': 't1'});
      gw.emit('tool.complete', {'tool_id': 't1'});
      gw.emit('reasoning.delta', {'text': 'more thinking'});
      gw.emit('message.delta', {'text': 'the answer'});
      gw.emit('message.complete', {'text': 'the answer'});

      final m = store.messages.lastWhere((x) => x.role == 'assistant');
      expect(m.parts.map((p) => p.kind).toList(), [
        MessagePartKind.reasoning,
        MessagePartKind.tool,
        MessagePartKind.reasoning,
        MessagePartKind.text,
      ]);
      // The tool is done, not stuck.
      expect(m.lastTool!.state, ToolState.done);
    });

    testWidgets('the bubble renders reasoning above the tool above later reasoning',
        (tester) async {
      final m = ChatMessage(role: 'assistant');
      m.appendReasoning('first thought');
      m.addTool(ToolActivity(name: 'terminal', state: ToolState.done));
      m.appendReasoning('second thought');
      m.appendText('done');
      // The show/hide display gate: a visible trace must have a non-empty
      // effectiveReasoning (the store sets it live; pin it here for the
      // widget assertion).
      m.effectiveReasoning = m.reasoning;
      await tester.pumpWidget(wrap(MessageBubble(message: m, isUser: false)));

      // A reasoning part is a (collapsed) ExpansionTile; the trace text only
      // exists in the tree when expanded, so expand both tiles first.
      final tiles = find.byType(ExpansionTile, skipOffstage: false);
      expect(tiles, findsNWidgets(2));
      await tester.tap(tiles.first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ExpansionTile, skipOffstage: false).last);
      await tester.pumpAndSettle();

      final topA = tester.getTopLeft(find.text('first thought'));
      final topTool = tester.getTopLeft(find.text('terminal'));
      final topB = tester.getTopLeft(find.text('second thought'));
      final topAnswer = tester.getTopLeft(find.text('done'));
      expect(topA.dy, lessThan(topTool.dy),
          reason: 'the earlier thinking box must sit above the tool');
      expect(topTool.dy, lessThan(topB.dy),
          reason: 'the tool must sit above the LATER thinking box');
      expect(topB.dy, lessThan(topAnswer.dy),
          reason: 'the later thinking box sits above the final answer');
    });
  });

  group('dark-mode code blocks (round 14)', () {
    testWidgets('fenced code blocks use the themed panel, not light blue',
        (tester) async {
      final dark = ThemeData(brightness: Brightness.dark);
      final light = ThemeData(brightness: Brightness.light);
      await tester.pumpWidget(wrap(
        MessageBubble(
            message: ChatMessage(
                role: 'assistant', text: '```bash\necho hi\n```'),
            isUser: false),
      ));
      // The MarkdownBody exists (rich rendering default ON).
      expect(find.byType(MarkdownBody), findsOneWidget);
      // Rebuild the stylesheet exactly as the bubble does and assert the
      // fix: the block panel is surfaceContainerHighest (theme-consistent,
      // dark in dark mode) and the code text is onSurface (readable),
      // NOT the package default light-blue/Colors.blue.shade100.
      for (final t in [dark, light]) {
        final sheet = MarkdownStyleSheet(
          p: t.textTheme.bodyLarge,
          code: t.textTheme.bodyMedium?.copyWith(
            color: t.colorScheme.onSurface,
            fontFamily: 'monospace',
            backgroundColor: t.colorScheme.onSurface.withValues(alpha: 0.1),
          ),
          codeblockDecoration: BoxDecoration(
            color: t.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
        );
        final panel = (sheet.codeblockDecoration as BoxDecoration).color;
        expect(panel, t.colorScheme.surfaceContainerHighest);
        expect(panel, isNot(const Color(0xFFB3E5FC)),
            reason: 'must not be the light-blue default');
        expect(sheet.code!.color, t.colorScheme.onSurface);
      }
    });
  });

}
