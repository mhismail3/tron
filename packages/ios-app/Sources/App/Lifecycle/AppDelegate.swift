import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        MetricKitDiagnosticsStore.shared.start()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(
            name: .deviceTokenDidUpdate,
            object: nil,
            userInfo: ["token": token]
        )
        TronLogger.shared.info("APNs issued a device token", category: .notification)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationCenter.default.post(
            name: .deviceTokenRegistrationFailed,
            object: nil,
            userInfo: ["error": error]
        )
        TronLogger.shared.error(
            "APNs registration failed: \(error.localizedDescription)",
            category: .notification
        )
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo["sessionId"] as? String
        let invocationId = userInfo["invocationId"] as? String
        DispatchQueue.main.async {
            var payload: [String: String] = [:]
            if let sessionId { payload["sessionId"] = sessionId }
            if let invocationId { payload["invocationId"] = invocationId }
            NotificationCenter.default.post(
                name: .navigateToSession,
                object: nil,
                userInfo: payload
            )
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let deviceTokenDidUpdate = Notification.Name("tron.deviceTokenDidUpdate")
    static let deviceTokenRegistrationFailed = Notification.Name("tron.deviceTokenRegistrationFailed")
    static let navigateToSession = Notification.Name("tron.navigateToSession")
}
