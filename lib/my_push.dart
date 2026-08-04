library my_push;

import 'dart:convert';
import 'dart:math';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/api_client.dart';

export 'src/api_client.dart' show ApiClient;

typedef NotificationClickHandler = void Function(Map<String, dynamic> data);
typedef ForegroundWillDisplay = bool Function(Map<String, dynamic> data);

/// Self-hosted push SDK — a simple OneSignal-like facade.
///
/// ```dart
/// await MyPush.instance.initialize(appKey: 'pub_...', apiBaseUrl: 'https://...');
/// await MyPush.instance.requestPermission();
/// MyPush.instance.onNotificationClick((data) { /* navigate */ });
/// ```
class MyPush {
  MyPush._();
  static final MyPush instance = MyPush._();

  static const _deviceIdKey = 'my_push_device_id';
  static const _androidChannelId = 'my_push_default';

  late ApiClient _api;
  String? _deviceId;
  bool _initialized = false;

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  NotificationClickHandler? _onClick;
  ForegroundWillDisplay? _foregroundGate;

  String? get deviceId => _deviceId;

  /// Initialize: register the device and wire listeners.
  ///
  /// By default the SDK fetches the Firebase client config from the backend and
  /// calls `Firebase.initializeApp()` for you — so the app needs no
  /// `flutterfire configure` or `google-services.json` / `GoogleService-Info.plist`.
  /// Just set the config once in the dashboard.
  ///
  /// If you already call `Firebase.initializeApp()` yourself, pass
  /// [autoInitializeFirebase] = false.
  Future<void> initialize({
    required String appKey,
    required String apiBaseUrl,
    bool autoInitializeFirebase = true,
  }) async {
    if (_initialized) return;
    _api = ApiClient(baseUrl: apiBaseUrl, appKey: appKey);

    if (autoInitializeFirebase && Firebase.apps.isEmpty) {
      await _initFirebaseFromBackend();
    }

    _deviceId = await _loadOrCreateDeviceId();
    await _setupLocalNotifications();
    await _registerDevice();
    _wireListeners();

    _initialized = true;
  }

  /// Fetch Firebase client options from the backend and initialize Firebase.
  Future<void> _initFirebaseFromBackend() async {
    final config = await _api.getConfig();
    final platformKey =
        defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    final opts = config[platformKey] as Map<String, dynamic>?;
    if (opts == null) {
      throw StateError(
        'No Firebase config for "$platformKey". Set it in the dashboard, or '
        'call Firebase.initializeApp() yourself and pass autoInitializeFirebase: false.',
      );
    }
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: opts['apiKey'] as String,
        appId: opts['appId'] as String,
        messagingSenderId: opts['messagingSenderId'] as String,
        projectId: opts['projectId'] as String,
        storageBucket: opts['storageBucket'] as String?,
        iosBundleId: opts['iosBundleId'] as String?,
      ),
    );
  }

  /// Request notification permission (iOS + Android 13+).
  Future<bool> requestPermission() async {
    final settings = await FirebaseMessaging.instance.requestPermission();
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  /// Link the user identity (external_user_id).
  Future<void> login(String externalId) async {
    if (_deviceId == null) return;
    await _api.setExternalUserId(_deviceId!, externalId);
  }

  /// External id clear.
  Future<void> logout() async {
    if (_deviceId == null) return;
    await _api.setExternalUserId(_deviceId!, null);
  }

  Future<void> setTag(String key, String value) =>
      setTags({key: value});

  Future<void> setTags(Map<String, String> tags) async {
    if (_deviceId == null) return;
    await _api.updateTags(_deviceId!, set: tags);
  }

  Future<void> deleteTag(String key) async {
    if (_deviceId == null) return;
    await _api.updateTags(_deviceId!, delete: [key]);
  }

  /// Register a click callback. You control app navigation yourself.
  void onNotificationClick(NotificationClickHandler handler) {
    _onClick = handler;
  }

  /// Optional: decide whether to display a notification in the foreground.
  /// Return `true` to show a system notification (default), `false` to suppress.
  void setForegroundWillDisplay(ForegroundWillDisplay gate) {
    _foregroundGate = gate;
  }

  // ── internals ──────────────────────────────────────────────

  Future<String> _loadOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id = _uuidV4();
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  Future<void> _setupLocalNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _local.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: (resp) {
        final payload = resp.payload;
        if (payload != null && payload.isNotEmpty) {
          _handleClick(_decodeData(payload));
        }
      },
    );

    // Android channel
    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
      _androidChannelId,
      'Notifications',
      importance: Importance.high,
    ));
  }

  Future<void> _registerDevice() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await _api.registerDevice({
        'device_id': _deviceId,
        'push_token': token,
        'platform': defaultTargetPlatform == TargetPlatform.iOS
            ? 'ios'
            : 'android',
      });
    } catch (e) {
      if (kDebugMode) print('[my_push] register failed: $e');
    }
  }

  void _wireListeners() {
    // Token refresh → re-register
    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      if (_deviceId == null) return;
      await _api.registerDevice({
        'device_id': _deviceId,
        'push_token': token,
        'platform':
            defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      });
    });

    // Foreground message → show local notification (default)
    FirebaseMessaging.onMessage.listen(_onForegroundMessage);

    // Background tap (app was opened)
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      _handleClick(_dataFromRemote(m));
    });

    // Tap from terminated state (initial message)
    FirebaseMessaging.instance.getInitialMessage().then((m) {
      if (m != null) _handleClick(_dataFromRemote(m));
    });
  }

  Future<void> _onForegroundMessage(RemoteMessage m) async {
    final data = _dataFromRemote(m);
    final show = _foregroundGate?.call(data) ?? true;
    if (!show) return;

    final n = m.notification;
    await _local.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      n?.title ?? data['title']?.toString(),
      n?.body ?? data['body']?.toString(),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannelId,
          'Notifications',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: jsonEncode(data),
    );
  }

  void _handleClick(Map<String, dynamic> data) {
    // Analytics: click report (fire-and-forget)
    final nid = data['notification_id']?.toString();
    if (nid != null && _deviceId != null) {
      _api.reportClick(nid, _deviceId!);
    }
    _onClick?.call(data);
  }

  Map<String, dynamic> _dataFromRemote(RemoteMessage m) {
    final map = <String, dynamic>{...m.data};
    if (m.notification?.title != null) map['title'] ??= m.notification!.title;
    if (m.notification?.body != null) map['body'] ??= m.notification!.body;
    return map;
  }

  Map<String, dynamic> _decodeData(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
  }

  // Minimal RFC-4122 v4 UUID (no external dep).
  String _uuidV4() {
    final rnd = _rng();
    final b = List<int>.generate(16, (_) => rnd.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String hex(int n) => n.toRadixString(16).padLeft(2, '0');
    final s = b.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
        '-${s.substring(16, 20)}-${s.substring(20)}';
  }
}

Random _rng() {
  try {
    return Random.secure();
  } catch (_) {
    return Random();
  }
}
