import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/notifications/notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('notification initialization failure does not escape into chat', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dexterous.com/flutter/local_notifications'),
          (call) async => throw PlatformException(code: 'denied'));
    await expectLater(TalariaNotifier().push(title: 'Reply', body: 'Finished'), completes);
  });
}
