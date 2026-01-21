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

        // Show banner, sound, and badge even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }

    /// Handle notification tap
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        TronLogger.shared.info("User tapped notification: \(userInfo)", category: .notification)

        // Extract sessionId for deep linking
        if let sessionId = userInfo["sessionId"] as? String {
            // Post notification for app to navigate to session
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .navigateToSession,
                    object: nil,
                    userInfo: ["sessionId": sessionId]
                )
            }
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
