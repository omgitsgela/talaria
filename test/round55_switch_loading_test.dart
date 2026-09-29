import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/store/chat_store.dart';

void main() {
  // Reported: switching between conversations is slow and shows no loading
  // screen. The transcript's loading state is `messages.isEmpty && loading`, so
  // the previous conversation's messages left on screen suppressed it entirely.
  group('dropping the transcript when switching conversations', () {
    test('switching to a DIFFERENT conversation drops it', () {
      expect(ChatStore.shouldClearTranscriptOnSwitch('stored-a', 'stored-b'),
          isTrue);
    });

    test('re-resuming the SAME conversation keeps it', () {
      // A stale-runtime recovery resumes the conversation already on screen:
      // clearing there would blank a transcript the user is reading.
      expect(ChatStore.shouldClearTranscriptOnSwitch('stored-a', 'stored-a'),
          isFalse);
    });

    test('the first open has nothing to drop', () {
      expect(ChatStore.shouldClearTranscriptOnSwitch(null, 'stored-a'), isFalse);
    });
  });
}
