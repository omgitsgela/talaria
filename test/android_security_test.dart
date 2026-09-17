import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('connection credentials are never written to plaintext preferences', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, isNot(contains('p.setString(')));
    expect(main, contains('FlutterSecureStorage'));
  });
  test('Android foreground service does not restart a dead Dart turn', () {
    final native = File(
            'android/app/src/main/kotlin/com/talaria/talaria/TalariaForegroundService.kt')
        .readAsStringSync();
    // START_NOT_STICKY: the OS must not resurrect this service (it cannot
    // recreate the Dart socket/turn anyway).
    expect(native, contains('START_NOT_STICKY'));
    expect(native, contains('setContentIntent'));
    // specialUse keeps the always-on gateway socket alive in the background
    // without a dataSync time budget (which would stop an idle connection).
    expect(native, contains('FOREGROUND_SERVICE_TYPE_SPECIAL_USE'));
    expect(native, contains('talaria_foreground'));
  });
  test('Android launcher icon has legacy and adaptive resources', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final adaptive =
        File('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml')
            .readAsStringSync();
    final themed =
        File('android/app/src/main/res/mipmap-anydpi-v33/ic_launcher.xml')
            .readAsStringSync();
    expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
    expect(manifest, contains('android:roundIcon="@mipmap/ic_launcher"'));
    expect(adaptive, contains('<adaptive-icon'));
    expect(adaptive, contains('@color/ic_launcher_background'));
    expect(adaptive, contains('@mipmap/ic_launcher_foreground'));
    expect(themed, contains('<monochrome'));
    for (final density in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
      expect(
          File('android/app/src/main/res/mipmap-$density/ic_launcher.png')
              .existsSync(),
          isTrue);
      expect(
          File('android/app/src/main/res/mipmap-$density/'
                  'ic_launcher_foreground.png')
              .existsSync(),
          isTrue);
    }
  });

  test(
      'Android prevents cloud backup of credentials and allows LAN gateway HTTP',
      () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, contains('android:usesCleartextTraffic="true"'));
  });
}
