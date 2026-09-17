import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/notifications/foreground.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('talaria/foreground');
  final calls = <String>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async { calls.add(call.method); return true; });
  });
  tearDown(() { debugDefaultTargetPlatformOverride = null; });
  test('Android starts and stops the native foreground service', () async {
    final keeper = ForegroundKeeper();
    await keeper.start();
    await keeper.stop();
    expect(calls, ['start', 'stop']);
  });
  test('failed start remains retryable', () async {
    var attempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      attempts++;
      if (attempts == 1) throw PlatformException(code: 'restricted');
      return true;
    });
    final keeper = ForegroundKeeper();
    await keeper.start(); await keeper.start();
    expect(attempts, 2);
  });
  test('concurrent start and stop leave the native service stopped', () async {
    final keeper = ForegroundKeeper();
    await Future.wait([keeper.start(), keeper.stop()]);
    expect(calls, ['start', 'stop']);
  });
  test('non Android is a no-op', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await ForegroundKeeper().start();
    expect(calls, isEmpty);
  });
}
