import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/gateway/oauth_flow.dart';

/// Round 49: a gateway restart ends an OAuth session, so say so.
///
/// The app already DETECTED this: `OAuthFlow.refresh` treats a 401
/// `session_expired` as the session being gone and drops the stored token set.
/// What was missing is that the sign-in screen never learned it, and kept
/// pre-filling the dead token from the config, so a session that had ENDED
/// looked identical to a live one. Two copies of the token, one of them stale.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url = 'http://192.168.0.142:9119';

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });


  group('the recorded reason a sign-in is needed', () {
    test('is absent until recorded, then reads back', () async {
      final store = OAuthTokenStore();
      expect(await store.reauthNeededReason(url), isNull);
      await store.markReauthNeeded(url, 'gateway_restart');
      expect(await store.reauthNeededReason(url), 'gateway_restart');
    });

    test('can be cleared again', () async {
      final store = OAuthTokenStore();
      await store.markReauthNeeded(url, 'gateway_restart');
      await store.clearReauthNeeded(url);
      expect(await store.reauthNeededReason(url), isNull);
    });

    test('is scoped to the gateway it was recorded for', () async {
      final store = OAuthTokenStore();
      await store.markReauthNeeded(url, 'gateway_restart');
      expect(await store.reauthNeededReason('http://other.local:9119'), isNull);
    });
  });
}
