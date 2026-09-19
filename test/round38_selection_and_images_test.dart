import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/widgets/message_bubble.dart';

Future<void> showMessage(WidgetTester tester, String text) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
        body: ListView(children: [
      MessageBubble(
          message: ChatMessage(role: 'assistant', text: text), isUser: false),
      const SizedBox(height: 1200),
    ])),
  ));
  await tester.pumpAndSettle();
}

void main() {
  const png =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

  testWidgets('embedded data image renders and opens a zoomable viewer',
      (tester) async {
    await showMessage(tester, png);
    expect(find.byType(Image), findsOneWidget);
    await tester.runAsync(() => precacheImage(
          tester.widget<Image>(find.byType(Image)).image,
          tester.element(find.byType(Image)),
        ));
    await tester.pumpAndSettle();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('markdown image syntax decodes pixels', (tester) async {
    await showMessage(tester, 'Here is a picture:\n\n![Red pixel]($png)');
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.semanticLabel, 'Red pixel');
    await tester.runAsync(
        () => precacheImage(image.image, tester.element(find.byType(Image))));
    await tester.pumpAndSettle();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(tester.getSize(find.byType(Image)).height, lessThanOrEqualTo(240));
  });

  testWidgets('failed HTTP image is labelled instead of a broken box',
      (tester) async {
    await showMessage(
        tester, '![Remote photo](https://example.invalid/photo.png)');
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Image unavailable: Remote photo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('malformed image data has a placeholder', (tester) async {
    await showMessage(tester, 'data:image/png;base64,not-valid-base64');
    expect(find.textContaining('Image unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('code examples stay text, not image attachments', (tester) async {
    await showMessage(tester, '```text\n@image:/gateway/photo.png\n```');
    expect(find.textContaining('Image unavailable'), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('gateway-only image has an honest placeholder', (tester) async {
    await showMessage(tester, '@image:/gateway/images/photo.png');
    expect(find.textContaining('Image unavailable'), findsOneWidget);
    expect(find.textContaining('gateway'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('touch vertical drag scrolls instead of selecting',
      (tester) async {
    await showMessage(
        tester, 'First paragraph here.\n\nSecond paragraph here.');
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    await tester.drag(
        find.text('First paragraph here.', findRichText: true).last,
        const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
  });

  for (final reasoning in [false, true]) {
    testWidgets(
        '${reasoning ? 'Reasoning' : 'Plain user text'} selects all paragraphs',
        (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      const text = 'First paragraph here.\n\nSecond paragraph here.';
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: MessageBubble(
        message: ChatMessage(
            role: reasoning ? 'assistant' : 'user',
            text: reasoning ? '' : text,
            reasoning: reasoning ? text : ''),
        isUser: !reasoning,
      ))));
      if (reasoning) {
        await tester.tap(find.text('Reasoning'));
        await tester.pumpAndSettle();
      }
      await tester.longPress(find.byType(SelectableText));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied, text);
    });
  }

  testWidgets('user attachment paths also have placeholders', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MessageBubble(
      message: ChatMessage(
          role: 'user', text: 'Photo\n@image:"/gateway/my photo.png"'),
      isUser: true,
    ))));
    expect(find.textContaining('Image unavailable'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('markdown selection crosses paragraph boundaries',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await showMessage(
        tester, 'First paragraph here.\n\nSecond paragraph here.');
    final first = find.text('First paragraph here.', findRichText: true).last;
    final second = find.text('Second paragraph here.', findRichText: true).last;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(tester.getTopLeft(first) + const Offset(1, 8));
    await mouse.moveTo(tester.getBottomRight(second) - const Offset(1, 8));
    await mouse.up();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(copied, contains('First paragraph here.'));
    expect(copied, contains('Second paragraph here.'));
    copied = null;
    await tester.longPress(first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, contains('First paragraph here.'));
    expect(copied, contains('Second paragraph here.'));
  });
}
