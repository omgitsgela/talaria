/// Unit tests for the MEDIA-tag parser (media_tags.dart) — the Dart port of
/// the desktop's parts.ts MEDIA machinery. Fixtures mirror the desktop's own
/// test cases (interior spaces anchored by extension, quoted values, trailing
/// sentence punctuation, degenerate captures, Windows/drive paths).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/widgets/media_tags.dart';

void main() {
  group('findMediaTags', () {
    test('whole-line tag', () {
      final tags = findMediaTags('MEDIA:/x/y.png');
      expect(tags, hasLength(1));
      expect(tags.single.path, '/x/y.png');
      expect(tags.single.kind, MediaKind.image);
    });

    test('inline tag in prose', () {
      final tags = findMediaTags('tail MEDIA:/x/y.png');
      expect(tags.single.start, 5);
    });

    test('absolute path with interior spaces anchored by extension', () {
      final tags =
          findMediaTags('Delivered MEDIA:/gateway/out/my photo.png end');
      expect(tags, hasLength(1));
      expect(tags.single.path, '/gateway/out/my photo.png');
    });

    test('quoted capture keeps odd punctuation inside the quotes', () {
      final tags = findMediaTags('see MEDIA:"/tmp/stop! file.png" next');
      expect(tags.single.path, '/tmp/stop! file.png');
      expect(tags.single.quoted, isTrue);
    });

    test('single-quoted capture closes the quote (review finding 1)', () {
      final tags = findMediaTags("see MEDIA:'/tmp/stop! file.pdf' next");
      expect(tags, hasLength(1));
      expect(tags.single.path, '/tmp/stop! file.pdf',
          reason: 'the leading quote must not leak into the path');
      expect(tags.single.quoted, isTrue);
    });

    test('bare capture sheds trailing sentence punctuation', () {
      final tags = findMediaTags('open MEDIA:/tmp/a.pdf.');
      expect(tags.single.path, '/tmp/a.pdf');
      expect(tags.single.punctuation, '.');
    });

    test('degenerate captures stay prose (isPlausibleMediaPath)', () {
      for (final text in [
        'prose with MEDIA: only',
        'MEDIA:...',
        "MEDIA:'",
        'MEDIA:word',
      ]) {
        expect(findMediaTags(text), isEmpty, reason: text);
      }
    });

    test('relative and unknown-extension paths via the bare branch', () {
      final tags = findMediaTags('built out/app-debug.apk for you');
      // The bare branch only fires after `MEDIA:`; a bare path in prose is
      // not a tag.
      expect(tags, isEmpty);
      final t2 = findMediaTags('built MEDIA:out/app-debug.apk for you');
      expect(t2.single.path, 'out/app-debug.apk');
      expect(t2.single.kind, MediaKind.file);
    });

    test('tilde and Windows drive anchors', () {
      expect(findMediaTags('MEDIA:~/notes/report.md').single.path,
          '~/notes/report.md');
      expect(findMediaTags('MEDIA:C:\\Users\\me\\plan.pdf').single.path,
          r'C:\Users\me\plan.pdf');
    });

    test('inline-code closer is not swallowed by the bare branch', () {
      final tags = findMediaTags('run `MEDIA:thing.md` now');
      expect(tags.single.path, 'thing.md');
    });

    test('data URL values are images', () {
      final tags = findMediaTags('look MEDIA:data:image/png;base64,AAA tail');
      expect(tags.single.path, 'data:image/png;base64,AAA');
      expect(tags.single.kind, MediaKind.image);
    });

    test('multiple tags on one line, document order', () {
      final tags = findMediaTags('MEDIA:/a.png then MEDIA:/b.pdf');
      expect(tags.map((t) => t.path), ['/a.png', '/b.pdf']);
    });
  });

  group('kinds and labels', () {
    test('mediaKindOf across the delivery table', () {
      expect(mediaKindOf('a.webp'), MediaKind.image);
      expect(mediaKindOf('a.tiff'), MediaKind.image);
      expect(mediaKindOf('clip.mp4'), MediaKind.video);
      expect(mediaKindOf('song.opus'), MediaKind.audio);
      expect(mediaKindOf('doc.docx'), MediaKind.file);
      expect(mediaKindOf('noext'), MediaKind.file);
      expect(mediaKindOf('https://x.test/img.png'), MediaKind.image);
    });

    test('mediaLeafName handles URLs, paths, and drive letters', () {
      expect(mediaLeafName('/gateway/out/my photo.png'), 'my photo.png');
      expect(mediaLeafName(r'C:\Users\me\plan.pdf'), 'plan.pdf');
      expect(mediaLeafName('https://x.test/a/b/photo.jpg?v=1'), 'photo.jpg');
      expect(mediaLeafName('plain'), 'plain');
    });
  });
}
