# my_push — Flutter Push SDK (OneSignal alternative)

Self-hosted push notifications via FCM (iOS = FCM→APNs relay). A simple, OneSignal-like API.

## Install (git package)

In `pubspec.yaml`:

```yaml
dependencies:
  my_push:
    git:
      url: https://github.com/Rehman-dh/MyPush.Package.git
      ref: main
```

Then:

```bash
flutter pub get
```

## Setup — zero config in the app (like OneSignal)

You do **not** need `flutterfire configure`, `firebase_options.dart`, or to bundle
`google-services.json` / `GoogleService-Info.plist` in the app. The SDK fetches the
Firebase config from the backend and initializes Firebase at runtime.

**One-time, in the dashboard** (Apps → your app → Firebase config):
- Paste your `google-services.json` (Android) and/or `GoogleService-Info.plist` (iOS).
  Get these from the Firebase Console → Project Settings → Your apps.

**iOS only, one-time in Xcode:** add the *Push Notifications* and
*Background Modes → Remote notifications* capabilities, and upload your APNs `.p8`
auth key in Firebase Console → Project Settings → Cloud Messaging. (OneSignal
requires this Xcode step too.)

That's it — the app just needs the **App Key**.

## Usage

```dart
import 'package:flutter/widgets.dart';
import 'package:my_push/my_push.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // SDK fetches Firebase config from the backend and initializes Firebase itself.
  await MyPush.instance.initialize(
    appKey: 'pub_xxxxxxxx',                       // App Key from the dashboard
    apiBaseUrl: 'https://your-dashboard.vercel.app',
  );
  await MyPush.instance.requestPermission();

  // On click → you navigate
  MyPush.instance.onNotificationClick((data) {
    // data e.g. { screen: 'order', order_id: 'A-100', notification_id: '...' }
  });

  runApp(const MyApp());
}
```

### Already initialize Firebase yourself?
If your app already calls `Firebase.initializeApp()` (e.g. you use other Firebase
services with `flutterfire configure`), skip the SDK's auto-init:

```dart
await MyPush.instance.initialize(
  appKey: 'pub_xxxxxxxx',
  apiBaseUrl: 'https://your-dashboard.vercel.app',
  autoInitializeFirebase: false,
);
```

### User identity
```dart
await MyPush.instance.login('4821');   // your app's user id
await MyPush.instance.logout();
```

### Tags (segmentation)
```dart
await MyPush.instance.setTag('city', 'lahore');
await MyPush.instance.setTags({'plan': 'premium', 'city': 'lahore'});
await MyPush.instance.deleteTag('city');
```

### Foreground control (optional)
```dart
// Return false to suppress the foreground banner
MyPush.instance.setForegroundWillDisplay((data) => true);
```

## Behaviour

- **Device id**: a locally generated UUID (`shared_preferences`) — your `subscription id`.
- **Registration**: on init the FCM token is sent to the backend; auto re-registers on `onTokenRefresh`.
- **Foreground**: shows a heads-up banner via `flutter_local_notifications` (default).
- **Click**: background (`onMessageOpenedApp`), terminated (`getInitialMessage`), and foreground-local-tap all funnel into `onNotificationClick`; click analytics are reported automatically.

## Notes
- To process data-only background messages you'll need a separate top-level `FirebaseMessaging.onBackgroundMessage` handler (v1 uses notification messages, so it isn't required).
