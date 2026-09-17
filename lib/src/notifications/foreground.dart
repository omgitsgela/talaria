import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the Dart isolate (and its gateway WebSocket) alive while the app is
/// backgrounded, via a native Android foreground service.
///
/// The service is a *connection* keep-alive, not a per-turn worker: the store
/// starts it on connect and leaves it running until an explicit close, so an
/// idle, backgrounded socket is not reaped by the OS and background task
/// execution / late events are not missed. Re-invoking `start` refreshes the
/// notification text (idempotent; `setOnlyAlertOnce` prevents re-alerting).
///
/// Best-effort: OS restrictions (missing permission, background-start denial,
/// quota) are swallowed — chat still works in the foreground.
class ForegroundKeeper {
  bool _active = false;
  Future<void> _pending = Future.value();
  static const MethodChannel _channel = MethodChannel('talaria/foreground');

  // Serialize operations so a stop during an in-flight start is never lost.
  Future<void> _enqueue(Future<void> Function() operation) {
    _pending = _pending.then((_) async {
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
      try { await operation(); } catch (_) {
        // Plugin unavailable or Android disallowed the request: chat still works.
      }
    });
    return _pending;
  }

  /// Start (or refresh) the keep-alive service with [title]/[text]. Idempotent:
  /// calling it again only updates the visible notification, it does not spawn
  /// a second service.
  Future<void> start({String title = 'Hermes connected', String text = 'Keeping your connection to the gateway alive.'}) => _enqueue(() async {
    await _channel.invokeMethod('start', {'title': title, 'text': text});
    _active = true;
  });

  Future<void> stop() => _enqueue(() async {
    if (!_active) return;
    await _channel.invokeMethod('stop');
    _active = false;
  });

  /// Update the visible notification text of an already-running service.
  Future<void> setTitle(String text) => _enqueue(() async {
    if (!_active) return;
    await _channel.invokeMethod('start', {'title': 'Hermes is working', 'text': text});
  });
}
