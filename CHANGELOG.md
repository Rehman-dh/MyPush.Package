# Changelog

## 0.1.0
- Initial release.
- Zero-config Firebase init (SDK fetches config from backend at runtime).
- Device registration + token refresh.
- Notification permission request.
- User identity: `login()` / `logout()`.
- Tags: `setTag` / `setTags` / `deleteTag`.
- Foreground display via `flutter_local_notifications` + suppress hook.
- Click / deep-link handling (background, terminated, foreground) with auto click analytics.
