import UIKit
@preconcurrency import UserNotifications

struct PushNotificationTap: Equatable, Sendable {
    let sessionID: String?
    let machineID: String?
    let requestID: String?

    init(sessionID: String?, machineID: String?, requestID: String? = nil) {
        self.sessionID = sessionID
        self.machineID = machineID
        self.requestID = requestID
    }

    var route: (sessionID: String, machineID: String)? {
        guard let sessionID, let machineID else { return nil }
        return (sessionID, machineID)
    }

    static func admit(_ userInfo: [AnyHashable: Any]) -> PushNotificationTap {
        let requestID = admitRequestID((userInfo["tron"] as? [AnyHashable: Any])?["requestId"])
        guard let sessionID = admitSessionID(userInfo["sessionId"]),
              let machineID = admitMachineID(userInfo["machineId"]) else {
            return PushNotificationTap(sessionID: nil, machineID: nil, requestID: requestID)
        }
        return PushNotificationTap(sessionID: sessionID, machineID: machineID, requestID: requestID)
    }

    private static func admitSessionID(_ value: Any?) -> String? {
        guard let candidate = value as? String,
              !candidate.isEmpty,
              candidate.utf8.count <= 160,
              candidate.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "-_:".unicodeScalars.contains($0)
              }) else { return nil }
        return candidate
    }

    private static func admitRequestID(_ value: Any?) -> String? {
        guard let candidate = value as? String,
              (8...160).contains(candidate.utf8.count),
              candidate.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
              }) else { return nil }
        return candidate
    }

    private static func admitMachineID(_ value: Any?) -> String? {
        guard let candidate = value as? String,
              !candidate.isEmpty,
              candidate.utf8.count <= 256,
              candidate.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return candidate
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    nonisolated(unsafe) var onDeviceToken: (@MainActor @Sendable (Data) -> Void)?
    nonisolated(unsafe) var onRegistrationFailure: (@MainActor @Sendable () -> Void)?
    private nonisolated(unsafe) var onNotificationTap: (@MainActor @Sendable (PushNotificationTap) -> Void)?
    private nonisolated(unsafe) var pendingNotificationTap: PushNotificationTap?

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

    @MainActor
    func installNotificationTapHandler(_ handler: @escaping @MainActor @Sendable (PushNotificationTap) -> Void) {
        onNotificationTap = handler
        guard let pendingNotificationTap else { return }
        self.pendingNotificationTap = nil
        handler(pendingNotificationTap)
    }

    @MainActor
    func deliverNotificationTap(_ tap: PushNotificationTap) {
        guard let onNotificationTap else {
            pendingNotificationTap = tap
            return
        }
        onNotificationTap(tap)
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
        await deliverNotificationTap(tap)
    }
}
