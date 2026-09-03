import AppKit
import Foundation
import os
import UserNotifications

// Notifications are used instead of modal alerts for conditions which need not be
// acknowledged before the app can continue. Whether a notification stays on screen
// until it is dismissed is determined by the notification style in System Settings.
// We ask for the persistent "Alerts" style with `NSUserNotificationAlertStyle` in
// Info.plist, but the user may change it in System Settings > Notifications.

class UserNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {

    static let shared = UserNotificationPresenter()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // Shows `errorMessage` in a system notification. Falls back to a modal alert if
    // we are not allowed to post notifications so that the message is not lost.
    func presentError(_ errorMessage: String, title: String) {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            // If the user has decided about notifications before, this returns the
            // previous decision without asking again.
            let isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if !isAuthorized {
                os_log("not authorized to post notifications, showing alert instead")
                NSAlert.presentError(errorMessage, title: title)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            // Error messages may be large, truncate to a limit which the notification can handle.
            content.body = String(errorMessage.prefix(1000))
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                os_log("could not post notification: %{public}@", error.localizedDescription)
                NSAlert.presentError(errorMessage, title: title)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .list, .sound]     // also show notifications while our app is frontmost
    }

}
