# iOS Notification Service Extension (rich media + background action buttons)

On iOS, action buttons on **background/terminated** notifications and reliable
big-picture images require a small native **Notification Service Extension (NSE)**
in your app. Android needs none of this — this file is iOS-only.

## 1. Add the target

Xcode → **File → New → Target… → Notification Service Extension**. Name it e.g.
`NotificationService`. When prompted, **don't** activate a separate scheme.

## 2. Category = the message's `apns.payload.aps.category`

The backend sets the category id to `mp_<notification_id>` when a push has
buttons. The NSE reads the buttons the backend also puts in the payload and
registers a matching category at delivery time, so the buttons appear even when
the app is not running.

Replace the generated `NotificationService.swift` with:

```swift
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
  var contentHandler: ((UNNotificationContent) -> Void)?
  var bestAttempt: UNMutableNotificationContent?

  override func didReceive(_ request: UNNotificationRequest,
                           withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
    self.contentHandler = contentHandler
    bestAttempt = (request.content.mutableCopy() as? UNMutableNotificationContent)
    guard let content = bestAttempt else { contentHandler(request.content); return }

    let userInfo = request.content.userInfo

    // Register the category + its actions from the payload's "buttons" JSON.
    if let category = userInfo["aps"] as? [String: Any],
       let categoryId = category["category"] as? String,
       let buttonsRaw = userInfo["buttons"] as? String,
       let data = buttonsRaw.data(using: .utf8),
       let buttons = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
      let actions = buttons.compactMap { b -> UNNotificationAction? in
        guard let id = b["id"] as? String, let text = b["text"] as? String else { return nil }
        return UNNotificationAction(identifier: id, title: text, options: [.foreground])
      }
      let cat = UNNotificationCategory(identifier: categoryId, actions: actions,
                                       intentIdentifiers: [], options: [])
      UNUserNotificationCenter.current().setNotificationCategories([cat])
      content.categoryIdentifier = categoryId
    }

    // Attach the image (big picture) if present.
    if let urlStr = (userInfo["image"] as? String), let url = URL(string: urlStr) {
      URLSession.shared.downloadTask(with: url) { tmp, _, _ in
        if let tmp = tmp {
          let dst = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".jpg")
          try? FileManager.default.moveItem(at: tmp, to: dst)
          if let att = try? UNNotificationAttachment(identifier: "image", url: dst) {
            content.attachments = [att]
          }
        }
        contentHandler(content)
      }.resume()
    } else {
      contentHandler(content)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    if let handler = contentHandler, let content = bestAttempt { handler(content) }
  }
}
```

## 3. Backend already cooperates

`buildFcmMessage` sends `apns.payload.aps["mutable-content"] = 1` (so the NSE
runs), the `category` id, the `buttons` JSON, and the `image` — no extra work.

That's it. With the NSE in place, iOS shows big-picture images and action
buttons for background/terminated notifications, matching Android.
