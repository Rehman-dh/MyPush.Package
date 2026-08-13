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

**One-time:** set your dashboard URL in `lib/my_push.dart`:

```dart
const String kDefaultApiBaseUrl = 'https://my-push-backend.vercel.app';
```

After this, apps only pass the **App Key** to `initialize()` — just like OneSignal
only needs an App ID. (You can still override per-call with `apiBaseUrl:`.)

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

  // Base URL is baked into the SDK (kDefaultApiBaseUrl) — apps pass only the App Key.
  await MyPush.instance.initialize(
    appKey: 'pub_xxxxxxxx',                        // App Key from the dashboard
  );
  await MyPush.instance.requestPermission();

  // On click → you navigate.
  MyPush.instance.onNotificationClick((data) {
    // data e.g. { screen: 'order', order_id: 'A-100', notification_id: '...' }
    // If an action button was tapped, data['action_id'] holds its id.
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
  apiBaseUrl: 'https://my-push-backend.vercel.app',
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

## Rich media & action buttons

Compose a push in the dashboard with an image (big picture), large icon, accent
color, subtitle (iOS), sound, and **action buttons**. The SDK renders all of it:

- **Foreground**: the SDK builds a rich local notification (big-picture image,
  large icon, accent color, iOS subtitle/attachment, buttons).
- **Background/terminated**: notifications *without* buttons are rendered by the
  system tray automatically. Notifications *with* buttons are sent as data-only
  messages and rendered by the SDK's background handler (already wired — no app
  code needed on Android).

When a button is tapped, `onNotificationClick` receives the normal `data` plus
`data['action_id']`.

### iOS action buttons (required setup)

iOS requires notification **categories** to be registered at init. Pass the
categories your buttons use via `iosCategories`:

```dart
await MyPush.instance.initialize(
  appKey: 'pub_xxxxxxxx',
  apiBaseUrl: 'https://my-push-backend.vercel.app',
  iosCategories: [
    DarwinNotificationCategory(
      'mp_default',
      actions: [
        DarwinNotificationAction.plain('accept', 'Accept'),
        DarwinNotificationAction.plain('decline', 'Decline'),
      ],
    ),
  ],
);
```

For **iOS background/terminated** action buttons to appear, add a
**Notification Service Extension** to your iOS app (Xcode → File → New → Target →
Notification Service Extension) and set the category. Android needs none of this.
Full snippet: see `IOS_NSE.md` (or the dashboard docs).

## Behaviour

- **Device id**: a locally generated UUID (`shared_preferences`) — your `subscription id`.
- **Registration**: on init the FCM token is sent to the backend; auto re-registers on `onTokenRefresh`.
- **Foreground**: builds a rich heads-up notification via `flutter_local_notifications` (image, large icon, color, subtitle, buttons).
- **Background**: a top-level `FirebaseMessaging.onBackgroundMessage` handler renders data-only (button-carrying) messages; plain notifications use the system tray.
- **Click**: background (`onMessageOpenedApp`), terminated (`getInitialMessage`), foreground-local-tap, and app-launch-from-local-notification all funnel into `onNotificationClick`; click analytics are reported automatically.
