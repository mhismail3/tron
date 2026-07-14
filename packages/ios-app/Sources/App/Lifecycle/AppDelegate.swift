import UIKit
import UserNotifications

/// Injectable lifecycle effects. `.live` is construction-inert: every Apple
/// singleton lookup happens inside a closure after the runtime-mode guard.
struct AppLifecycleEffects: @unchecked Sendable {
    var installNotificationDelegate: (UNUserNotificationCenterDelegate) -> Void
    var startMetricKit: () -> Void
    var publishDeviceToken: (String) -> Void
    var publishRegistrationFailure: (Error) -> Void
    var publishNavigation: ([AnyHashable: Any]) -> Void
    var logTokenIssued: () -> Void
    var logRegistrationFailure: (Error) -> Void

    static var live: Self {
        Self(
            installNotificationDelegate: { delegate in
                UNUserNotificationCenter.current().delegate = delegate
            },
            startMetricKit: {
                MetricKitDiagnosticsStore.shared.start()
            },
            publishDeviceToken: { token in
                NotificationCenter.default.post(
                    name: .deviceTokenDidUpdate,
                    object: nil,
                    userInfo: ["token": token]
                )
            },
            publishRegistrationFailure: { error in
                NotificationCenter.default.post(
                    name: .deviceTokenRegistrationFailed,
                    object: nil,
                    userInfo: ["error": error]
                )
            },
            publishNavigation: { userInfo in
                let sessionId = userInfo["sessionId"] as? String
                let invocationId = userInfo["invocationId"] as? String
                var payload: [String: String] = [:]
                if let sessionId { payload["sessionId"] = sessionId }
                if let invocationId { payload["invocationId"] = invocationId }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .navigateToSession,
                        object: nil,
                        userInfo: payload
                    )
                }
            },
            logTokenIssued: {
                TronLogger.shared.info("APNs issued a device token", category: .notification)
            },
            logRegistrationFailure: { error in
                TronLogger.shared.error(
                    "APNs registration failed: \(error.localizedDescription)",
                    category: .notification
                )
            }
        )
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    nonisolated let runtimeMode: AppRuntimeMode
    nonisolated let effects: AppLifecycleEffects

    override convenience init() {
        self.init(
            runtimeMode: .current,
            effects: .live
        )
    }

    init(runtimeMode: AppRuntimeMode, effects: AppLifecycleEffects) {
        self.runtimeMode = runtimeMode
        self.effects = effects
        super.init()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard runtimeMode.runsApplicationLifecycle else { return true }
        effects.installNotificationDelegate(self)
        effects.startMetricKit()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard runtimeMode.runsApplicationLifecycle else { return }
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        effects.publishDeviceToken(token)
        effects.logTokenIssued()
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        guard runtimeMode.runsApplicationLifecycle else { return }
        effects.publishRegistrationFailure(error)
        effects.logRegistrationFailure(error)
    }

}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func completeNotificationPresentation(
        _ completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(runtimeMode.runsApplicationLifecycle ? [.banner, .sound] : [])
    }

    nonisolated func completeNotificationResponse(
        userInfo: [AnyHashable: Any],
        completionHandler: @escaping () -> Void
    ) {
        if runtimeMode.runsApplicationLifecycle {
            effects.publishNavigation(userInfo)
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completeNotificationPresentation(completionHandler)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completeNotificationResponse(
            userInfo: response.notification.request.content.userInfo,
            completionHandler: completionHandler
        )
    }
}

extension Notification.Name {
    static let deviceTokenDidUpdate = Notification.Name("tron.deviceTokenDidUpdate")
    static let deviceTokenRegistrationFailed = Notification.Name("tron.deviceTokenRegistrationFailed")
    static let navigateToSession = Notification.Name("tron.navigateToSession")
}
