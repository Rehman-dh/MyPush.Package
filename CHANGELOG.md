# Changelog

## 0.3.0
- Rich foreground notifications: big-picture image, large icon, accent color,
  iOS subtitle + image attachment, custom sound.
- **Action buttons**: parsed from the push and rendered with tap handling;
  `onNotificationClick` now receives `data['action_id']` when a button is tapped.
- Background handler (`onBackgroundMessage`) renders data-only (button-carrying)
  messages; plain notifications continue to use the system tray.
- `initialize(iosCategories: [...])` to register iOS notification categories.
- App-launch-from-local-notification taps are now delivered to `onNotificationClick`.
- See `IOS_NSE.md` for the iOS Notification Service Extension (background buttons + images).

## 0.2.0
- **Breaking** minimum `flutter_local_notifications` is now 20.0.0. That release
  converted `initialize()` and `show()` from positional to named parameters, and
  this package now calls the named form — 17.x–19.x no longer compile.
- Widened `firebase_core` to `>=3.6.0 <5.0.0` and `firebase_messaging` to
  `>=15.1.3 <17.0.0`. The old `^3.6.0` / `^15.1.3` pins made the package
  impossible to resolve in any app already on the Firebase 4.x set.

## 0.1.0
- Initial release.
- Zero-config Firebase init (SDK fetches config from backend at runtime).
- Device registration + token refresh.
- Notification permission request.
- User identity: `login()` / `logout()`.
- Tags: `setTag` / `setTags` / `deleteTag`.
- Foreground display via `flutter_local_notifications` + suppress hook.
- Click / deep-link handling (background, terminated, foreground) with auto click analytics.
