/// MEDIA: delivery-tag parser — the Dart port of the desktop client's
/// `apps/desktop/src/lib/chat-messages/parts.ts` MEDIA machinery.
///
/// The agent delivers files by naming them in its reply with a `MEDIA:` tag
/// (the same contract `gateway/platforms/base.py` uses for messaging
/// platforms). The desktop parses these tags ANYWHERE in the prose, not only
/// on their own line, and so does this. The tag value is one of:
///
/// * a quoted value (backtick / double / single quote — the escape hatch for
///   names with odd punctuation),
/// * an absolute path anchored on a known deliverable extension, which may
///   contain interior spaces (`MEDIA:/tmp/my photo.png`), or
/// * a bare non-space word (relative paths, unknown extensions).
///
/// Degenerate captures (`MEDIA:...`, a lone quote, a bare English word) are
/// treated as prose: a dead link is worse than no link (#84361 in the
/// desktop tracker). Sentence punctuation that trails a bare capture is not
/// part of the path (`MEDIA:/tmp/a.pdf.` keeps its period in the sentence).
library;

/// Deliverable extensions — mirrors `MEDIA_DELIVERY_EXTS` in the desktop's
/// parts.ts and the Python-side `MEDIA_DELIVERY_EXTS` in
/// `gateway/platforms/base.py` so all three surfaces agree on which MEDIA:
/// paths are valid.
const List<String> mediaDeliveryExts = [
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'tiff',
  'svg',
  'mp4',
  'mov',
  'avi',
  'mkv',
  'webm',
  '3gp',
  'mp3',
  'm2a',
  'wav',
  'ogg',
  'opus',
  'm4a',
  'flac',
  'pdf',
  'docx',
  'doc',
  'odt',
  'rtf',
  'txt',
  'md',
  'epub',
  'xlsx',
  'xls',
  'ods',
  'csv',
  'tsv',
  'json',
  'xml',
  'yaml',
  'yml',
  'kmz',
  'kml',
  'geojson',
  'gpx',
  'pptx',
  'ppt',
  'odp',
  'key',
  'zip',
  'tar',
  'gz',
  'tgz',
  'bz2',
  'xz',
  '7z',
  'rar',
  'apk',
  'ipa',
  'html',
  'htm',
];

// Sort longest-first so the alternation never matches a shorter extension as
// a prefix of a longer one.
final String _mediaExtAlternation = (mediaDeliveryExts.toList()
      ..sort((a, b) => b.length.compareTo(a.length)))
    .join('|');

/// Unquoted absolute-path branch: path anchor, interior whitespace allowed,
/// end anchored on a known deliverable extension. Mirrors
/// `_MEDIA_PATH_ANCHORED` in the desktop.
final String _mediaPathAnchored =
    r'(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:'
    '$_mediaExtAlternation'
    r")(?=[\s`\x22'*_,;:)\]}]|MEDIA:|$)";

/// Bare-word fallback for paths the anchored branch misses. Stops before a
/// backtick or double quote so an inline-code closer is not swallowed;
/// apostrophes stay legal inside the path.
const String _mediaPathBare = r'[^\s`"]+';

/// Inline MEDIA tag, anywhere in prose. Mirrors `MEDIA_TAG_RE` in the
/// desktop: an optional wrapping quote, `MEDIA:`, then the capture group.
/// Each quoted branch captures its CLOSING quote too (the TS original keeps
/// `'…'` whole inside the capture — an unbalanced leading quote in the path
/// is worse than a dead link).
final RegExp mediaTagRe = RegExp('[`"\x27]?MEDIA:\\s*'
    '('
    '`[^`\\n]+`'
    '|"[^"\\n]+"'
    "|'[^'\\n]+'"
    '|$_mediaPathAnchored'
    '|$_mediaPathBare'
    ')'
    '[`"\x27]?');

/// Sentence punctuation that can trail a bare capture when the tag sits in
/// prose.
const String _mediaTrailingPunctuation = '.,;:!?\u2026';

/// Whether a capture can name a real deliverable: a path separator, or a dot
/// with file content after it (`report.md`, `.env`, `../a.png`). Anything
/// else (`...`, a lone quote, a bare English word) stays prose. Mirrors the
/// desktop's `isPlausibleMediaPath`.
bool isPlausibleMediaPath(String value) =>
    value.contains('/') ||
    value.contains(r'\') ||
    RegExp(r'\.[^.]').hasMatch(value);

/// Shed the wrapping quote (backtick / double / single), and a trailing
/// backtick or double quote left as formatting residue. Apostrophes are not
/// residue (`john's.md`). Mirrors the desktop's `unquoteMediaPath`.
String unquoteMediaPath(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2) {
    final quote = trimmed[0];
    if ((quote == '`' || quote == '"' || quote == "'") &&
        trimmed.endsWith(quote)) {
      return trimmed.substring(1, trimmed.length - 1);
    }
  }
  final last = trimmed.substring(trimmed.length - 1);
  return (last == '`' || last == '"')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

/// Split a bare (unquoted) capture into path + trailing sentence punctuation.
/// Punctuation only counts as prose while what precedes it still names a
/// path, so an ellipsis (`MEDIA:...`) never splits into a degenerate capture.
/// Mirrors the desktop's `splitTrailingPunctuation`.
({String path, String punctuation}) splitTrailingPunctuation(String value) {
  var end = value.length;
  while (end > 0 && _mediaTrailingPunctuation.contains(value[end - 1])) {
    if (!isPlausibleMediaPath(value.substring(0, end - 1))) break;
    end -= 1;
  }
  return (
    path: value.substring(0, end),
    punctuation: value.substring(end),
  );
}

enum MediaKind { image, video, audio, file }

const Set<String> _imageExts = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'tiff',
  'svg'
};
const Set<String> _videoExts = {'mp4', 'mov', 'avi', 'mkv', 'webm', '3gp'};
const Set<String> _audioExts = {
  'mp3',
  'm2a',
  'wav',
  'ogg',
  'opus',
  'm4a',
  'flac'
};

/// Extension of a path/URL source (query/fragment stripped), lowercased, or
/// '' when there is none.
String mediaExtension(String source) {
  final stem = source.split(RegExp(r'[?#]')).first;
  final dot = stem.lastIndexOf('.');
  if (dot == -1 || dot == stem.length - 1) return '';
  final ext = stem.substring(dot + 1).toLowerCase();
  return mediaDeliveryExts.contains(ext) ? ext : '';
}

/// What kind of deliverable a MEDIA source names. Mirrors the desktop's
/// `mediaKind`: unknown extensions fall through to `file`.
MediaKind mediaKindOf(String source) {
  if (source.startsWith('data:image/')) return MediaKind.image;
  if (source.startsWith('data:video/')) return MediaKind.video;
  if (source.startsWith('data:audio/')) return MediaKind.audio;
  final ext = mediaExtension(source);
  if (_imageExts.contains(ext)) return MediaKind.image;
  if (_videoExts.contains(ext)) return MediaKind.video;
  if (_audioExts.contains(ext)) return MediaKind.audio;
  return MediaKind.file;
}

/// A parsed MEDIA tag from a message's text.
class MediaTagMatch {
  MediaTagMatch({
    required this.start,
    required this.end,
    required this.path,
    required this.punctuation,
    required this.quoted,
  });

  /// Character span of the whole tag (including its `MEDIA:` prefix) in the
  /// source text.
  final int start;
  final int end;

  /// The unquoted, punctuation-shed path the tag names.
  final String path;

  /// Sentence punctuation that trailed a bare capture — prose that must stay
  /// in the text after the media renders.
  final String punctuation;

  /// Whether the capture was quoted (the documented escape hatch: everything
  /// inside the quotes is part of the path).
  final bool quoted;

  MediaKind get kind => mediaKindOf(path);
}

/// Every valid MEDIA tag in [text], in document order. Degenerate captures
/// are skipped (they render as prose).
List<MediaTagMatch> findMediaTags(String text) {
  final found = <MediaTagMatch>[];
  for (final m in mediaTagRe.allMatches(text)) {
    final raw = m.group(1) ?? '';
    final trimmed = raw.trim();
    final quote = trimmed.isEmpty ? '' : trimmed[0];
    final quoted = trimmed.length >= 2 &&
        (quote == '`' || quote == '"' || quote == "'") &&
        trimmed.endsWith(quote);
    final split = quoted
        ? (path: unquoteMediaPath(raw), punctuation: '')
        : splitTrailingPunctuation(unquoteMediaPath(raw));
    final path = split.path;
    if (!isPlausibleMediaPath(path)) continue;
    found.add(MediaTagMatch(
      start: m.start,
      end: m.end,
      path: path,
      punctuation: split.punctuation,
      quoted: quoted,
    ));
  }
  return found;
}

/// The leaf name of a MEDIA path — the label a chip / image caption shows.
/// Mirrors the desktop's `mediaName` (a Windows drive letter is a path, not a
/// URL scheme).
String mediaLeafName(String path) {
  if (!RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path)) {
    final uri = Uri.tryParse(path);
    if (uri != null && uri.hasScheme && uri.scheme != 'data') {
      final leaf = uri.pathSegments.where((s) => s.isNotEmpty).isEmpty
          ? ''
          : uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (leaf.isNotEmpty) return leaf;
    }
  }
  final parts = path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}
