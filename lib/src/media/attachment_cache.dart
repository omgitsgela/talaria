import 'dart:typed_data';

/// Retains the bytes of images the app has just handled, so a photo the user
/// sent can be shown in the conversation.
///
/// Why this exists: the transcript refers to a sent photo by the server-side
/// path the gateway staged it to, and a phone cannot fetch that path. The bytes
/// were in hand moments earlier (they came from the picker), so they are kept
/// here under the same identifier and the transcript draws from them. Anything
/// missing from here falls back to the placeholder, which is the honest answer
/// for a reloaded session or another device.
///
/// Process-local and bounded twice over, by total bytes and by entry count, so a
/// long session cannot grow it without limit.
class AttachmentCache {
  AttachmentCache._();

  /// Total bytes retained. Phone photos are a few MB, so this holds a handful.
  static const int maxTotalBytes = 24 * 1024 * 1024;

  /// Entries retained regardless of size.
  static const int maxEntries = 16;

  /// An image above this is not retained at all: one photo must not consume the
  /// whole budget and evict everything else.
  static const int maxEntryBytes = 8 * 1024 * 1024;

  /// Insertion-ordered, so the oldest key is first and eviction is O(1).
  static final Map<String, Uint8List> _entries = <String, Uint8List>{};
  static int _bytes = 0;

  /// Entries currently retained.
  static int get length => _entries.length;

  /// Bytes currently retained.
  static int get totalBytes => _bytes;

  /// Retains [bytes] under [key], which is the staged path the gateway returned
  /// for the image and the identifier the stored transcript refers to.
  static void put(String key, Uint8List bytes) {
    if (key.isEmpty || bytes.isEmpty || bytes.length > maxEntryBytes) return;
    final replaced = _entries.remove(key);
    if (replaced != null) _bytes -= replaced.length;
    _entries[key] = bytes;
    _bytes += bytes.length;
    while (_entries.length > maxEntries ||
        (_bytes > maxTotalBytes && _entries.length > 1)) {
      final oldest = _entries.keys.first;
      _bytes -= _entries.remove(oldest)!.length;
    }
  }

  /// The retained bytes for a source taken out of message text, or null.
  ///
  /// An exact match on the staged path first. Failing that, a single matching
  /// basename is accepted, because history may store a shorter form of the same
  /// path. An ambiguous basename is refused rather than guessed: showing the
  /// wrong photo would be worse than showing none.
  static Uint8List? bytesFor(String source) {
    if (source.isEmpty) return null;
    final exact = _entries[source];
    if (exact != null) return exact;
    final name = _basename(source);
    if (name.isEmpty) return null;
    Uint8List? found;
    for (final entry in _entries.entries) {
      if (_basename(entry.key) == name) {
        if (found != null) return null;
        found = entry.value;
      }
    }
    return found;
  }

  static String _basename(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final cut = normalized.lastIndexOf('/');
    return cut == -1 ? normalized : normalized.substring(cut + 1);
  }

  /// Drops everything. Used by tests, and after a session teardown when the
  /// retained copies no longer correspond to anything on screen.
  static void clear() {
    _entries.clear();
    _bytes = 0;
  }
}
