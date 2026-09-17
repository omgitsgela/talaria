import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Best-effort notifications; permission/plugin failures never break chat.
class TalariaNotifier {
  static const _channelId = 'talaria_updates';
  static const _channelName = 'Hermes replies';
  static final pendingSession = ValueNotifier<String?>(null);
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _disposed = false;
  Future<void>? _initializing;
  static int _nextId = 100;

  Future<void> init() async {
    if (_ready || _disposed || kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    await (_initializing ??= _initialize());
    _initializing = null;
  }

  Future<void> _initialize() async {
    try {
      final initialized = await _plugin.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (response) => _open(response.payload),
      );
      if (initialized != true || _disposed) return;
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        _channelId, _channelName, importance: Importance.high,
        description: 'Replies and requests from your Hermes gateway.',
      ));
      await android?.requestNotificationsPermission();
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) _open(launch?.notificationResponse?.payload);
      _ready = !_disposed;
    } catch (_) { _ready = false; }
  }

  void _open(String? payload) {
    if (!_disposed && payload != null && payload.isNotEmpty) pendingSession.value = payload;
  }

  Future<void> push({required String title, required String body, String? tag, int? id, String? sessionId}) async {
    try {
      await init();
      if (!_ready || _disposed) return;
      await _plugin.show(id ?? _nextId++, title, body,
        NotificationDetails(android: AndroidNotificationDetails(
          _channelId, _channelName, importance: Importance.high,
          priority: Priority.high, tag: tag, visibility: NotificationVisibility.private,
        )), payload: sessionId);
    } catch (_) { /* Notifications must not interrupt the conversation. */ }
  }

  void dispose() { _disposed = true; }
}
