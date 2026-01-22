import UIKit
import UserNotifications

/// App delegate for handling push notifications.
/// Uses UIApplicationDelegateAdaptor to integrate with SwiftUI.
class AppDelegate: NSObject, UIApplicationDelegate {
    /// Current device token (hex string)
    private(set) var deviceToken: String?

    // MARK: - UIApplicationDelegate

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Set notification center delegate for foreground handling
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Convert token to hex string
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        self.deviceToken = tokenString

        TronLogger.shared.info("Registered for remote notifications", category: .notification)

        // Post notification for observers
        NotificationCenter.default.post(
            name: .deviceTokenDidUpdate,
            object: nil,
            userInfo: ["token": tokenString]
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        TronLogger.shared.error("Failed to register for remote notifications: \(error.localizedDescription)", category: .notification)

        // Post notification for observers
        NotificationCenter.default.post(
            name: .deviceTokenRegistrationFailed,
            object: nil,
            userInfo: ["error": error]
        )
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Handle notification when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        TronLogger.shared.debug("Received notification in foreground: \(userInfo)", category: .notification)

        // Show banner and sound when app is in foreground, but NOT badge
        // (user is already in the app, no need to increment badge)
        completionHandler([.banner, .sound])
    }

    /// Handle notification tap
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        TronLogger.shared.info("User tapped notification: \(userInfo)", category: .notification)

        // Extract values as Sendable types for async dispatch
        guard let sessionId = userInfo["sessionId"] as? String else {
            completionHandler()
            return
        }
        let toolCallId = userInfo["toolCallId"] as? String
        let eventId = userInfo["eventId"] as? String

        // Post notification with extracted payload for deep link router
        DispatchQueue.main.async {
            var payload: [String: String] = ["sessionId": sessionId]
            if let toolCallId = toolCallId {
                payload["toolCallId"] = toolCallId
            }
            if let eventId = eventId {
                payload["eventId"] = eventId
            }
            NotificationCenter.default.post(
                name: .navigateToSession,
                object: nil,
                userInfo: payload
            )
        }

        completionHandler()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when device token is received from APNS
    static let deviceTokenDidUpdate = Notification.Name("deviceTokenDidUpdate")

    /// Posted when device token registration fails
    static let deviceTokenRegistrationFailed = Notification.Name("deviceTokenRegistrationFailed")

    /// Posted when user taps a notification to navigate to a session
    static let navigateToSession = Notification.Name("navigateToSession")
}
