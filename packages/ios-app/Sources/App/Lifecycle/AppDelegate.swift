import UIKit

/// Injectable lifecycle effects. `.live` is construction-inert: MetricKit
/// starts only after the runtime-mode guard.
struct AppLifecycleEffects: @unchecked Sendable {
    var startMetricKit: () -> Void

    static var live: Self {
        Self(
            startMetricKit: {
                MetricKitDiagnosticsStore.shared.start()
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
        return true
    }
}
