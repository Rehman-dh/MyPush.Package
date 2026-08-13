library my_push;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show Color;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'src/api_client.dart';

export 'src/api_client.dart' show ApiClient;

typedef NotificationClickHandler = void Function(Map<String, dynamic> data);
typedef ForegroundWillDisplay = bool Function(Map<String, dynamic> data);

const String _kChannelId = 'my_push_default';
const String _kChannelName = 'Notifications';

/// Your self-hosted dashboard's base URL, baked into the SDK so host apps only
/// need to pass the App Key (like OneSignal only needs an App ID). Set this once
/// to your deployment; apps can still override it per-call via `apiBaseUrl`.
const String kDefaultApiBaseUrl = 'https://my-push-backend.vercel.app';

/// Self-hosted push SDK — a simple OneSignal-like facade.
///
/// ```dart
/// // Base URL is baked in (kDefaultApiBaseUrl) — apps pass only the App Key:
/// await MyPush.instance.initialize(appKey: 'pub_...');
/// await MyPush.instance.requestPermission();
/// MyPush.instance.onNotificationClick((data) {
///   // data['action_id'] is set when an action button was tapped.
/// });
/// ```
class MyPush {
  MyPush._();
  static final MyPush instance = MyPush._();

  static const _deviceIdKey = 'my_push_device_id';

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
  /// [iosCategories] lets the host app pre-register iOS notification categories
  /// so action buttons work on iOS (iOS requires categories at init time). See
  /// the README for the recommended setup and the Notification Service Extension.
  Future<void> initialize({
    required String appKey,
    String? apiBaseUrl,
    bool autoInitializeFirebase = true,
    List<DarwinNotificationCategory>? iosCategories,
  }) async {
    if (_initialized) return;
    final base = (apiBaseUrl ?? kDefaultApiBaseUrl).trim();
    if (base.isEmpty || base.contains('YOUR-DASHBOARD')) {
      throw ArgumentError(
        'my_push: set kDefaultApiBaseUrl in my_push.dart to your dashboard URL, '
        'or pass apiBaseUrl to initialize().',
      );
    }
    _api = ApiClient(baseUrl: base, appKey: appKey);

    if (autoInitializeFirebase && Firebase.apps.isEmpty) {
      await _initFirebaseFromBackend();
    }

    _deviceId = await _loadOrCreateDeviceId();
    await _setupLocalNotifications(iosCategories);
    await _registerDevice();
    _wireListeners();
    await _handleLaunchFromLocalNotification();

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

  Future<void> setTag(String key, String value) => setTags({key: value});

  Future<void> setTags(Map<String, String> tags) async {
    if (_deviceId == null) return;
    await _api.updateTags(_deviceId!, set: tags);
  }

  Future<void> deleteTag(String key) async {
    if (_deviceId == null) return;
    await _api.updateTags(_deviceId!, delete: [key]);
  }

  /// Register a click callback. You control app navigation yourself.
  /// When an action button was tapped, `data['action_id']` is present.
  void onNotificationClick(NotificationClickHandler handler) {
    _onClick = handler;
  }

  /// Optional: decide whether to display a notification in the foreground.
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

  Future<void> _setupLocalNotifications(
    List<DarwinNotificationCategory>? iosCategories,
  ) async {
    final android = const AndroidInitializationSettings('@mipmap/ic_launcher');
    final ios = DarwinInitializationSettings(
      notificationCategories: iosCategories ?? const [],
    );
    await _local.initialize(
      settings: InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: (resp) {
        _handleResponse(resp);
      },
      onDidReceiveBackgroundNotificationResponse: _mpBackgroundResponse,
    );

    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
      _kChannelId,
      _kChannelName,
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
        'platform':
            defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      });
    } catch (e) {
      if (kDebugMode) print('[my_push] register failed: $e');
    }
  }

  void _wireListeners() {
    FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      if (_deviceId == null) return;
      await _api.registerDevice({
        'device_id': _deviceId,
        'push_token': token,
        'platform':
            defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
      });
    });

    // Foreground message → build a rich local notification (default).
    FirebaseMessaging.onMessage.listen(_onForegroundMessage);

    // Background data-only messages (e.g. with action buttons) → render them.
    FirebaseMessaging.onBackgroundMessage(_mpFirebaseBackgroundHandler);

    // Body tap that opened the app (from a system-tray FCM notification).
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      _handleClick(_dataFromRemote(m));
    });

    // Tap from terminated state (FCM notification).
    FirebaseMessaging.instance.getInitialMessage().then((m) {
      if (m != null) _handleClick(_dataFromRemote(m));
    });
  }

  /// Handle the case where a *local* notification (data-only push) launched the app.
  Future<void> _handleLaunchFromLocalNotification() async {
    final details = await _local.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp == true) {
      final resp = details!.notificationResponse;
      if (resp != null) _handleResponse(resp);
    }
  }

  Future<void> _onForegroundMessage(RemoteMessage m) async {
    final data = _dataFromRemote(m);
    final show = _foregroundGate?.call(data) ?? true;
    if (!show) return;

    final details = await _buildDetails(data);
    await _local.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: (data['title'] ?? m.notification?.title)?.toString(),
      body: (data['body'] ?? m.notification?.body)?.toString(),
      notificationDetails: details,
      payload: jsonEncode(data),
    );
  }

  void _handleResponse(NotificationResponse resp) {
    final data = _decodeData(resp.payload ?? '');
    if (resp.actionId != null && resp.actionId!.isNotEmpty) {
      data['action_id'] = resp.actionId;
    }
    _handleClick(data);
  }

  void _handleClick(Map<String, dynamic> data) {
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

// ── shared notification builders (used by foreground + background isolate) ──

Future<Uint8List?> _download(String? url) async {
  if (url == null || url.isEmpty) return null;
  try {
    final res = await http.get(Uri.parse(url));
    if (res.statusCode == 200) return res.bodyBytes;
  } catch (_) {}
  return null;
}

Color? _parseColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  var h = hex.replaceAll('#', '').trim();
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}

List<Map<String, dynamic>> _parseButtons(dynamic raw) {
  if (raw is! String || raw.isEmpty) return const [];
  try {
    final d = jsonDecode(raw);
    if (d is List) {
      return d.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
  } catch (_) {}
  return const [];
}

/// Build platform notification details from a push `data` map. Downloads the
/// image/large-icon and attaches action buttons when present.
Future<NotificationDetails> _buildDetails(Map<String, dynamic> data) async {
  final buttons = _parseButtons(data['buttons']);
  final androidActions = buttons
      .map((b) => AndroidNotificationAction(
            b['id']?.toString() ?? '',
            b['text']?.toString() ?? '',
          ))
      .toList();

  final imageBytes = await _download(data['image']?.toString());
  final largeIconBytes = await _download(data['large_icon']?.toString());
  final largeIcon =
      largeIconBytes != null ? ByteArrayAndroidBitmap(largeIconBytes) : null;

  StyleInformation? style;
  if (imageBytes != null) {
    style = BigPictureStyleInformation(
      ByteArrayAndroidBitmap(imageBytes),
      largeIcon: largeIcon,
    );
  }

  final android = AndroidNotificationDetails(
    _kChannelId,
    _kChannelName,
    importance: Importance.high,
    priority: Priority.high,
    color: _parseColor(data['accent_color']?.toString()),
    largeIcon: largeIcon,
    styleInformation: style,
    actions: androidActions.isNotEmpty ? androidActions : null,
    sound: (data['android_sound'] is String &&
            (data['android_sound'] as String).isNotEmpty)
        ? RawResourceAndroidNotificationSound(data['android_sound'] as String)
        : null,
  );

  final iosAttachments = <DarwinNotificationAttachment>[];
  if (imageBytes != null) {
    try {
      final f = File(
          '${Directory.systemTemp.path}/mp_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await f.writeAsBytes(imageBytes);
      iosAttachments.add(DarwinNotificationAttachment(f.path));
    } catch (_) {}
  }
  final ios = DarwinNotificationDetails(
    subtitle: data['subtitle']?.toString(),
    attachments: iosAttachments.isNotEmpty ? iosAttachments : null,
    categoryIdentifier:
        buttons.isNotEmpty ? 'mp_${data['notification_id']}' : null,
  );

  return NotificationDetails(android: android, iOS: ios);
}

/// Background FCM handler (separate isolate). Renders **data-only** messages
/// (e.g. those carrying action buttons); messages with a `notification` block
/// are already shown by the system tray, so we skip them to avoid duplicates.
@pragma('vm:entry-point')
Future<void> _mpFirebaseBackgroundHandler(RemoteMessage message) async {
  if (message.notification != null) return; // system tray already showed it
  final data = Map<String, dynamic>.from(message.data);
  if (data['title'] == null) return;

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    ),
  );
  final details = await _buildDetails(data);
  await plugin.show(
    id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    title: data['title']?.toString(),
    body: data['body']?.toString(),
    notificationDetails: details,
    payload: jsonEncode(data),
  );
}

/// Background tap/action handler (separate isolate). The click is re-processed
/// via the launch details when the app opens, so this is a best-effort no-op.
@pragma('vm:entry-point')
void _mpBackgroundResponse(NotificationResponse response) {}
