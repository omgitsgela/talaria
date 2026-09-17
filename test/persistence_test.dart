import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talaria/main.dart';
import 'package:talaria/src/gateway/config.dart';

void main() {
  late FlutterSecureStoragePlatform original;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    original = FlutterSecureStoragePlatform.instance;
  });
  tearDown(() => FlutterSecureStoragePlatform.instance = original);
  TestFlutterSecureStoragePlatform install() {
    final fake = TestFlutterSecureStoragePlatform({});
    FlutterSecureStoragePlatform.instance = fake;
    return fake;
  }
  FlutterSecureStorage using() => const FlutterSecureStorage();
  test('saves a complete connection and restores it from secure storage only',
      () async {
    final fake = install();
    final persistence = ConnectionPersistence(storage: using());
    final config = GatewayConfig(
        url: 'https://example.internal:9119', token: 'secret-token',
        oauthToken: 'oauth-secret', headers: {'X-Proxy': 'value'});
    await persistence.save(config);
    expect(fake.data.keys, ['talaria.connection']);
    final restored = await persistence.load();
    expect(restored?.toMap(), config.toMap());
    expect(restored?.token, 'secret-token');
  });
  test('legacy plaintext connection is deleted and never loaded', () async {
    SharedPreferences.setMockInitialValues({'talaria.connection': jsonEncode(
        {'url': 'http://10.0.0.5:9119', 'token': 'legacy-secret'})});
    final fake = install();
    final persistence = ConnectionPersistence(storage: using());
    expect(await persistence.load(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('talaria.connection'), isNull);
    expect(fake.data, isEmpty);
  });
  test('corrupt secure record is deleted and yields no connection', () async {
    final fake = install()..data['talaria.connection'] = 'not-json';
    final persistence = ConnectionPersistence(storage: using());
    expect(await persistence.load(), isNull);
    expect(fake.data, isEmpty);
  });
}