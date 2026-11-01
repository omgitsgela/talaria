// Round 58 — inline media delivery + bubble-wide text selection.
//
// Two features, desktop-parity inspired (the desktop's parts.ts / media.ts /
// markdown-text.tsx):
// 1. `MEDIA:` delivery tags render ANYWHERE in prose, not only on their own
//    line: image kinds become pictures (tappable, zoomable), every other
//    kind becomes a tappable chip naming the file that opens a detail sheet
//    (name, kind, full path, copy-path). Degenerate captures stay prose.
// 2. One SelectionArea per bubble: "Select all" / drag-select spans every
//    text part of the message, and fenced code text is copyable.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/widgets/message_bubble.dart';

void main() {
  const png =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

  Future<void> showMessage(WidgetTester tester, String text,
      {String role = 'assistant'}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: ListView(children: [
        MessageBubble(
            message: ChatMessage(role: role, text: text),
            isUser: role == 'user'),
        const SizedBox(height: 1200),
      ])),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('inline MEDIA: tag in prose renders an image', (tester) async {
    await showMessage(tester, 'Look at this: MEDIA:$png end of sentence.');
    expect(find.byType(Image), findsOneWidget,
        reason: 'inline MEDIA tag should render as an image');
  });

  testWidgets('inline MEDIA path with spaces anchored by ext', (tester) async {
    await showMessage(
        tester, 'Delivered MEDIA:/gateway/output/my photo.png for you.');
    // Image kind -> an (unavailable) image frame, NOT the raw tag text.
    expect(find.textContaining('MEDIA:'), findsNothing,
        reason: 'the tag must never render as raw text');
    expect(find.textContaining('Image unavailable'), findsOneWidget,
        reason: 'a gateway-side image keeps the honest placeholder');
  });

  testWidgets('two MEDIA tags on one line render as TWO media, not one',
      (tester) async {
    // Round-58 review finding 2: the legacy whole-line prefix matcher used
    // to glue everything after the first MEDIA: into a single bogus source.
    await showMessage(tester, 'MEDIA:/gateway/a.pdf then MEDIA:/gateway/b.png');
    expect(find.textContaining('MEDIA:'), findsNothing);
    expect(find.textContaining('a.pdf'), findsOneWidget,
        reason: 'the pdf tag becomes a named chip');
    expect(find.textContaining('Image unavailable'), findsOneWidget,
        reason: 'the png tag becomes an image frame');
  });

  testWidgets('single-quoted MEDIA value keeps both quotes off the path',
      (tester) async {
    // Round-58 review finding 1: the closing quote must be part of the
    // capture; a leading quote must never leak into the chip/path.
    await showMessage(tester, "see MEDIA:'/gateway/stop! report.pdf' next");
    expect(find.textContaining("'/gateway"), findsNothing,
        reason: 'a leading quote must not leak into the path');
    expect(find.textContaining('report.pdf'), findsOneWidget);
  });

  testWidgets('tab-indented MEDIA tag stays literal text', (tester) async {
    // Round-58 review finding 4: tab-indented lines are indented code and
    // the markdown rewriter must not touch them.
    await showMessage(tester, '\tMEDIA:/gateway/a.pdf');
    expect(find.textContaining('MEDIA:/gateway/a.pdf', findRichText: true),
        findsOneWidget,
        reason: 'the literal tag text survives in indented code');
  });

  testWidgets('block chip keeps trailing sentence punctuation', (tester) async {
    // Round-58 review finding 5: `MEDIA:/a.pdf.` on its own line must not
    // swallow the sentence's period into the chip. User role pins the
    // plain-text render path (markdown would fold the period into the
    // paragraph's rich text, which find.text cannot address).
    await showMessage(tester, 'MEDIA:/gateway/a.pdf.', role: 'user');
    expect(find.textContaining('a.pdf'), findsOneWidget);
    expect(find.text('.'), findsOneWidget,
        reason: 'the trailing period stays as prose');
  });

  testWidgets('selection spans multiple text parts of one bubble',
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
    final m = ChatMessage(role: 'assistant', text: '');
    m.appendText('Alpha paragraph.');
    m.addTool(ToolActivity(name: 'terminal', state: ToolState.done));
    m.appendText('Beta paragraph.');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: ListView(children: [
        MessageBubble(message: m, isUser: false),
        const SizedBox(height: 1200),
      ])),
    ));
    await tester.pumpAndSettle();
    await tester
        .longPress(find.text('Alpha paragraph.', findRichText: true).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, contains('Alpha paragraph.'));
    expect(copied, contains('Beta paragraph.'),
        reason: 'select-all should span every text part of the bubble');
  });

  testWidgets('fenced code block text is selectable', (tester) async {
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
    await showMessage(tester, '```python\nprint("hello world")\n```');
    await tester
        .longPress(find.textContaining('print', findRichText: true).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, isNotNull, reason: 'code text should be copyable');
  });

  testWidgets('text next to an image in the same bubble is selectable',
      (tester) async {
    // Round-58 review finding 6 (was a print, not an assertion): the image
    // renders, AND the caption text still selects + copies inside the same
    // bubble's single selection region.
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
    await showMessage(tester, 'Caption text.\n$png');
    expect(find.byType(Image), findsOneWidget);
    await tester.longPress(find.text('Caption text.'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, contains('Caption text.'),
        reason: 'the region beside an image still selects and copies');
  });

  testWidgets('image frame keeps its natural size in the transcript',
      (tester) async {
    // The old code FORCED every transcript image into a 320x240 letterbox.
    // Now the frame hugs the image's own aspect ratio inside the same
    // maximums: never upscaled, never boxed into empty space. Assert
    // behaviorally against the decoded pixels rather than a guessed size.
    const widePng =
        'iVBORw0KGgoAAAANSUhEUgAAAGQAAAAqCAYAAAD+en9mAAAAOklEQVR4nO3BMQEAAADCoPVPbQwfoAAAAAAAAAAAAAAAAAAAAAAAAIC3AcUMAAQABQAF3QAAAABJRU5ErkJggg==';
    await showMessage(tester, 'data:image/png;base64,$widePng', role: 'user');
    final size = tester.getSize(find.byType(Image));
    // The OLD code forced every image to exactly 320x240; this fixture is a
    // 100x42 wide image, so any layout equal to the old forced box is the
    // regression.
    expect(size, isNot(const Size(320, 240)),
        reason: 'the old forced letterbox must be gone');
    expect(size.width, lessThanOrEqualTo(320));
    expect(size.height, lessThanOrEqualTo(240));
  });
}
