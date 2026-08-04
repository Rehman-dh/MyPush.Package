import 'dart:convert';
import 'package:http/http.dart' as http;

/// Thin HTTP client for the push backend. Public App Key on every request.
class ApiClient {
  ApiClient({required this.baseUrl, required this.appKey});

  final String baseUrl;
  final String appKey;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-App-Key': appKey,
      };

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  /// GET /api/config — Firebase client options for runtime init.
  /// Returns e.g. { "android": {...}, "ios": {...} }.
  Future<Map<String, dynamic>> getConfig() async {
    final res = await http.get(_uri('/api/config'), headers: _headers);
    if (res.statusCode >= 300) {
      _check(res, 'getConfig');
      return {};
    }
    final decoded = jsonDecode(res.body);
    return decoded is Map<String, dynamic> ? decoded : {};
  }

  /// POST /api/devices — register/upsert.
  Future<void> registerDevice(Map<String, dynamic> body) async {
    final res = await http.post(_uri('/api/devices'),
        headers: _headers, body: jsonEncode(body));
    _check(res, 'registerDevice');
  }

  /// PATCH /api/devices/{id} — set/clear external_user_id.
  Future<void> setExternalUserId(String deviceId, String? externalId) async {
    final res = await http.patch(_uri('/api/devices/$deviceId'),
        headers: _headers,
        body: jsonEncode({'external_user_id': externalId}));
    _check(res, 'setExternalUserId');
  }

  /// PATCH /api/devices/{id}/tags — merge/delete tags.
  Future<void> updateTags(
    String deviceId, {
    Map<String, String>? set,
    List<String>? delete,
  }) async {
    final res = await http.patch(_uri('/api/devices/$deviceId/tags'),
        headers: _headers,
        body: jsonEncode({
          if (set != null) 'set': set,
          if (delete != null) 'delete': delete,
        }));
    _check(res, 'updateTags');
  }

  /// POST /api/events — click report.
  Future<void> reportClick(String notificationId, String deviceId) async {
    final res = await http.post(_uri('/api/events'),
        headers: _headers,
        body: jsonEncode({
          'notification_id': notificationId,
          'device_id': deviceId,
          'type': 'clicked',
        }));
    _check(res, 'reportClick');
  }

  void _check(http.Response res, String op) {
    if (res.statusCode >= 300) {
      // Non-fatal: log, don't crash the app.
      // ignore: avoid_print
      print('[my_push] $op failed: ${res.statusCode} ${res.body}');
    }
  }
}
