import 'package:flutter/widgets.dart';

import 'store/app_model.dart';

/// Exposes the [AppModel] to the widget tree.
class AppScope extends InheritedNotifier<AppModel> {
  const AppScope({super.key, required AppModel model, required Widget child})
      : _model = model,
        super(notifier: model, child: child);

  final AppModel _model;
  AppModel get model => _model;

  static AppModel of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Null-safe variant for surfaces that may exist above an [AppScope]
  /// (tests pump a bare [HomeScreen] with a [HomeScreen.storeOverride]).
  static AppModel? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier;
}
