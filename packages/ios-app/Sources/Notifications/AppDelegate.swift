import UIKit
@preconcurrency import UserNotifications

struct PushNotificationTap: Equatable, Sendable {
    let sessionID: String?

    static func admit(_ userInfo: [AnyHashable: Any]) -> PushNotificationTap {
        guard let candidate = userInfo["sessionId"] as? String,
              !candidate.isEmpty,
              candidate.utf8.count <= 160,
              candidate.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "-_:".unicodeScalars.contains($0)
              }) else {
            return PushNotificationTap(sessionID: nil)
        }
        return PushNotificationTap(sessionID: candidate)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    nonisolated(unsafe) var onDeviceToken: (@MainActor @Sendable (Data) -> Void)?
    nonisolated(unsafe) var onRegistrationFailure: (@MainActor @Sendable () -> Void)?
    nonisolated(unsafe) var onNotificationTap: (@MainActor @Sendable (PushNotificationTap) -> Void)?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let callback = onDeviceToken
        Task { @MainActor in callback?(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let callback = onRegistrationFailure
        Task { @MainActor in callback?() }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let tap = PushNotificationTap.admit(response.notification.request.content.userInfo)
        let callback = onNotificationTap
        await MainActor.run { callback?(tap) }
    }
}
