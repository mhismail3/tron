import Foundation
import Testing
import UIKit

@testable import TronMobile

@Suite("App delegate runtime effects")
@MainActor
struct AppDelegateTests {
    private final class Counters {
        var metricStarts = 0
        var notificationInstalls = 0
        var tokens = 0
    }

    private func makeEffects(_ counters: Counters) -> AppLifecycleEffects {
        AppLifecycleEffects(
            startMetricKit: { counters.metricStarts += 1 },
            installNotificationLifecycle: { counters.notificationInstalls += 1 },
            registeredForRemoteNotifications: { _ in counters.tokens += 1 },
            failedRemoteNotificationRegistration: { _ in },
            handleRemoteNotification: { _, completion in completion(.noData) }
        )
    }

    @Test("hosted launch has zero effects")
    func hostedCallbacksAreInert() {
        let counters = Counters()
        let delegate = AppDelegate(
            runtimeMode: .hostedUnitTests,
            effects: makeEffects(counters)
        )

        #expect(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        #expect(counters.metricStarts == 0)
        #expect(counters.notificationInstalls == 0)
        delegate.application(
            UIApplication.shared,
            didRegisterForRemoteNotificationsWithDeviceToken: Data([1, 2])
        )
        #expect(counters.tokens == 0)
    }

    @Test("application launch starts MetricKit once")
    func applicationCallbacksRunOnce() {
        let counters = Counters()
        let delegate = AppDelegate(runtimeMode: .application, effects: makeEffects(counters))

        #expect(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        #expect(counters.metricStarts == 1)
        #expect(counters.notificationInstalls == 1)
        delegate.application(
            UIApplication.shared,
            didRegisterForRemoteNotificationsWithDeviceToken: Data([1, 2])
        )
        #expect(counters.tokens == 1)
    }

    @Test("default delegate resolves hosted mode in the injected unit-test host")
    func defaultDelegateIsHosted() {
        let delegate = AppDelegate()
        #expect(delegate.runtimeMode == .hostedUnitTests)
    }
}
