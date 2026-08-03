import UIKit

/// Injectable lifecycle effects. `.live` is construction-inert: MetricKit
/// starts only after the runtime-mode guard.
struct AppLifecycleEffects: @unchecked Sendable {
    var startMetricKit: () -> Void
    var installNotificationLifecycle: @MainActor () -> Void
    var registeredForRemoteNotifications: @MainActor (Data) -> Void
    var failedRemoteNotificationRegistration: @MainActor (Error) -> Void
    var handleRemoteNotification: @MainActor (
        [AnyHashable: Any],
        @escaping (UIBackgroundFetchResult) -> Void
    ) -> Void

    static var live: Self {
        Self(
            startMetricKit: {
                MetricKitDiagnosticsStore.shared.start()
            },
            installNotificationLifecycle: {
                NotificationLifecycleBridge.shared.install()
            },
            registeredForRemoteNotifications: { token in
                NotificationLifecycleBridge.shared.didRegisterForRemoteNotifications(token: token)
            },
            failedRemoteNotificationRegistration: { error in
                NotificationLifecycleBridge.shared.didFailToRegisterForRemoteNotifications(error)
            },
            handleRemoteNotification: { payload, completion in
                NotificationLifecycleBridge.shared.handleQuietRefresh(
                    payload,
                    completion: completion
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
        effects.startMetricKit()
        effects.installNotificationLifecycle()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard runtimeMode.runsApplicationLifecycle else { return }
        effects.registeredForRemoteNotifications(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        guard runtimeMode.runsApplicationLifecycle else { return }
        effects.failedRemoteNotificationRegistration(error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard runtimeMode.runsApplicationLifecycle else {
            completionHandler(.noData)
            return
        }
        effects.handleRemoteNotification(userInfo, completionHandler)
    }
}
