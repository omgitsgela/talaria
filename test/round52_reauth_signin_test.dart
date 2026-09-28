import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/native_oauth.dart';

void main() {
  group('offering the native sign-in action', () {
    test('a gateway known to support the native flow offers it', () {
      expect(
        NativeOAuthService.shouldOfferNativeSignIn(
            nativeAvailable: true, reauthNeeded: false),
        isTrue,
      );
    });

    test('a recorded reauth offers it even when the probe could not confirm', () {
      // The probe needs a working credential, so a just-expired token is
      // exactly the case where it cannot answer. The button must still exist,
      // or the reauth message cannot be acted on.
      expect(
        NativeOAuthService.shouldOfferNativeSignIn(
            nativeAvailable: false, reauthNeeded: true),
        isTrue,
      );
    });

    test('an ordinary gateway with no native flow and no reauth does not', () {
      expect(
        NativeOAuthService.shouldOfferNativeSignIn(
            nativeAvailable: false, reauthNeeded: false),
        isFalse,
      );
    });
  });
}
