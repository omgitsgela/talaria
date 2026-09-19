import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/media/attachment_cache.dart';
import 'package:talaria/src/models/models.dart';
import 'package:talaria/src/widgets/message_bubble.dart';

/// A real 1x1 PNG, so anything that renders is rendering actual image bytes.
final Uint8List pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');

Future<void> showUserMessage(WidgetTester tester, String text) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
        body: ListView(children: [
      MessageBubble(
          message: ChatMessage(role: 'user', text: text), isUser: true),
      const SizedBox(height: 1200),
    ])),
  ));
  await tester.pumpAndSettle();
}

void main() {
  // The cache is process-local state, so every test starts from empty.
  setUp(AttachmentCache.clear);
  tearDown(AttachmentCache.clear);

  group('cache behaviour', () {
    test('returns bytes under the exact staged path', () {
      AttachmentCache.put('/srv/sessions/a/img_1.png', pngBytes);
      expect(AttachmentCache.bytesFor('/srv/sessions/a/img_1.png'), pngBytes);
    });

    test('matches a shorter form when the basename is unambiguous', () {
      // History may name only the file; a single match is safe to use.
      AttachmentCache.put('/srv/sessions/a/img_1.png', pngBytes);
      expect(AttachmentCache.bytesFor('img_1.png'), pngBytes);
    });

    test('refuses an ambiguous basename rather than guessing', () {
      AttachmentCache.put('/srv/sessions/a/img_1.png', pngBytes);
      AttachmentCache.put('/srv/sessions/b/img_1.png', Uint8List.fromList(pngBytes));
      // Two different photos share the name: showing either could be wrong.
      expect(AttachmentCache.bytesFor('img_1.png'), isNull);
      // Exact paths still resolve to their own bytes.
      expect(AttachmentCache.bytesFor('/srv/sessions/b/img_1.png'), isNotNull);
    });

    test('an exact path wins over a same-named other entry', () {
      final other = Uint8List.fromList(pngBytes)..[0] = 0;
      AttachmentCache.put('/srv/a/img_1.png', other);
      AttachmentCache.put('/srv/b/img_1.png', pngBytes);
      expect(AttachmentCache.bytesFor('/srv/a/img_1.png'), other);
    });

    test('entry count is bounded, oldest evicted first', () {
      for (var i = 0; i < AttachmentCache.maxEntries + 3; i++) {
        AttachmentCache.put('/srv/img_$i.png', Uint8List.fromList(pngBytes));
      }
      expect(AttachmentCache.length, AttachmentCache.maxEntries);
      expect(AttachmentCache.bytesFor('/srv/img_0.png'), isNull);
      expect(AttachmentCache.bytesFor('/srv/img_18.png'), isNotNull);
    });

    test('total bytes are bounded', () {
      final big = Uint8List(7 * 1024 * 1024); // under maxEntryBytes
      for (var i = 0; i < 4; i++) {
        AttachmentCache.put('/srv/big_$i.png', big);
      }
      // 4 x 7MB exceeds the 24MB budget, so the oldest went.
      expect(AttachmentCache.totalBytes, lessThanOrEqualTo(
          AttachmentCache.maxTotalBytes));
      expect(AttachmentCache.bytesFor('/srv/big_0.png'), isNull);
      expect(AttachmentCache.bytesFor('/srv/big_3.png'), isNotNull);
    });

    test('an oversized image is not retained at all', () {
      AttachmentCache.put('/srv/huge.png',
          Uint8List(AttachmentCache.maxEntryBytes + 1));
      expect(AttachmentCache.length, 0);
      expect(AttachmentCache.bytesFor('/srv/huge.png'), isNull);
    });

    test('clear drops everything', () {
      AttachmentCache.put('/srv/img_1.png', pngBytes);
      AttachmentCache.clear();
      expect(AttachmentCache.length, 0);
      expect(AttachmentCache.bytesFor('/srv/img_1.png'), isNull);
    });
  });

  group('transcript echo', () {
    testWidgets('a sent photo renders from the retained bytes', (tester) async {
      const path = '/srv/sessions/a/img_1.png';
      AttachmentCache.put(path, pngBytes);
      await showUserMessage(tester, '@image:$path');
      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('Image unavailable'), findsNothing);
    });

    testWidgets('an unobtainable image still shows the placeholder',
        (tester) async {
      // Nothing retained: a reloaded session, another device, or an eviction.
      await showUserMessage(tester, '@image:/srv/sessions/a/img_9.png');
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('Image unavailable'), findsOneWidget);
    });

    testWidgets('a data URL image is unaffected by the cache', (tester) async {
      await showUserMessage(
          tester, 'data:image/png;base64,${base64Encode(pngBytes)}');
      expect(find.byType(Image), findsOneWidget);
    });
  });
}
