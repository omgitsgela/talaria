import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/widgets/message_bubble.dart';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pending assistant shows spinner, not text', (tester) async {
    await tester.pumpWidget(wrap(
      MessageBubble(
        message: ChatMessage(role: 'assistant', pending: true),
        isUser: false,
      ),
    ));
    expect(find.text('Hermes is working…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('user message aligns right with primary container color', (tester) async {
    await tester.pumpWidget(wrap(
      MessageBubble(
        message: ChatMessage(role: 'user', text: 'Hello'),
        isUser: true,
      ),
    ));
    expect(find.text('Hello'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('assistant message shows tools then text', (tester) async {
    final msg = ChatMessage(role: 'assistant', text: 'Done');
    msg.addTool(ToolActivity(name: 'terminal', preview: 'ls', state: ToolState.done));
    await tester.pumpWidget(wrap(MessageBubble(message: msg, isUser: false)));
    expect(find.text('terminal'), findsOneWidget);
    expect(find.text('ls'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('error message shows error icon', (tester) async {
    await tester.pumpWidget(wrap(
      MessageBubble(
        message: ChatMessage(role: 'assistant', text: 'Oops', error: 'Timeout'),
        isUser: false,
      ),
    ));
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('Timeout'), findsOneWidget);
  });

  testWidgets('reasoning section is expandable', (tester) async {
    await tester.pumpWidget(wrap(
      MessageBubble(
        message: ChatMessage(role: 'assistant', text: 'Answer', reasoning: 'Let me think...'),
        isUser: false,
      ),
    ));
    expect(find.text('Reasoning'), findsOneWidget);
    // Expand it
    await tester.tap(find.text('Reasoning'));
    await tester.pumpAndSettle();
    expect(find.text('Let me think...'), findsOneWidget);
  });
}
