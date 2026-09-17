import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/screens/settings_screen.dart';
import 'package:talaria/src/store/chat_store.dart';
import 'settings_review_test.dart' as fixture;

void main() {
  testWidgets('model picker preserves slash-containing model and custom provider', (tester) async {
    final gw = fixture.SettingsGateway();
    gw.handler = (method, params) {
      if (method == 'model.options') {
        return {
          'model': 'old', 'provider': 'old',
          'providers': [
            {'slug': 'custom:lab', 'is_current': false, 'authenticated': true,
             'models': ['vendor/model-v1']},
          ],
        };
      }
      if (method == 'config.set') return {'value': 'vendor/model-v1'};
      if (method == 'config.get') return {'value': 'auto'};
      return {};
    };
    final store = ChatStore(config: fixture.config, client: gw);
    addTearDown(store.dispose);
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(store: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Use'));
    await tester.pumpAndSettle();
    final call = gw.calls.singleWhere((c) => c.$1 == 'config.set');
    expect(call.$2['value'], 'vendor/model-v1 --provider custom:lab');
  });
}
