import Foundation
import Testing
import UIKit

@testable import TronMobile

@Suite("App delegate runtime effects")
@MainActor
struct AppDelegateTests {
    private final class Counters {
        var metricStarts = 0
    }

    private func makeEffects(_ counters: Counters) -> AppLifecycleEffects {
        AppLifecycleEffects(
            startMetricKit: { counters.metricStarts += 1 }
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
    }

    @Test("application launch starts MetricKit once")
    func applicationCallbacksRunOnce() {
        let counters = Counters()
        let delegate = AppDelegate(runtimeMode: .application, effects: makeEffects(counters))

        #expect(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        #expect(counters.metricStarts == 1)
    }

    @Test("default delegate resolves hosted mode in the injected unit-test host")
    func defaultDelegateIsHosted() {
        let delegate = AppDelegate()
        #expect(delegate.runtimeMode == .hostedUnitTests)
    }
}
