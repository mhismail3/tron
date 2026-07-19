import Foundation
import Testing
import UIKit
import UserNotifications

@testable import TronMobile

@Suite("App delegate runtime effects")
@MainActor
struct AppDelegateTests {
    private final class Counters {
        var delegateInstalls = 0
        var metricStarts = 0
        var tokens: [String] = []
        var failures = 0
        var navigations = 0
        var tokenLogs = 0
        var failureLogs = 0
    }

    private struct ProbeError: Error {}

    private func makeEffects(_ counters: Counters) -> AppLifecycleEffects {
        AppLifecycleEffects(
            installNotificationDelegate: { _ in counters.delegateInstalls += 1 },
            startMetricKit: { counters.metricStarts += 1 },
            publishDeviceToken: { counters.tokens.append($0) },
            publishRegistrationFailure: { _ in counters.failures += 1 },
            publishNavigation: { _ in counters.navigations += 1 },
            logTokenIssued: { counters.tokenLogs += 1 },
            logRegistrationFailure: { _ in counters.failureLogs += 1 }
        )
    }

    @Test("hosted launch and APNs callbacks have zero effects")
    func hostedCallbacksAreInert() {
        let counters = Counters()
        let delegate = AppDelegate(
            runtimeMode: .hostedUnitTests,
            effects: makeEffects(counters)
        )

        #expect(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        delegate.application(
            UIApplication.shared,
            didRegisterForRemoteNotificationsWithDeviceToken: Data([0x01, 0xaf])
        )
        delegate.application(
            UIApplication.shared,
            didFailToRegisterForRemoteNotificationsWithError: ProbeError()
        )
        var presentationOptions: UNNotificationPresentationOptions?
        var responseCompleted = false
        delegate.completeNotificationPresentation { presentationOptions = $0 }
        delegate.completeNotificationResponse(userInfo: ["sessionId": "hosted"]) {
            responseCompleted = true
        }

        #expect(counters.delegateInstalls == 0)
        #expect(counters.metricStarts == 0)
        #expect(counters.tokens.isEmpty)
        #expect(counters.failures == 0)
        #expect(counters.tokenLogs == 0)
        #expect(counters.failureLogs == 0)
        #expect(presentationOptions?.isEmpty == true)
        #expect(responseCompleted)
        #expect(counters.navigations == 0)
    }

    @Test("application launch and APNs callbacks preserve live semantics")
    func applicationCallbacksRunOnce() {
        let counters = Counters()
        let delegate = AppDelegate(runtimeMode: .application, effects: makeEffects(counters))

        #expect(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        delegate.application(
            UIApplication.shared,
            didRegisterForRemoteNotificationsWithDeviceToken: Data([0x01, 0xaf])
        )
        delegate.application(
            UIApplication.shared,
            didFailToRegisterForRemoteNotificationsWithError: ProbeError()
        )
        var presentationOptions: UNNotificationPresentationOptions?
        var responseCompleted = false
        delegate.completeNotificationPresentation { presentationOptions = $0 }
        delegate.completeNotificationResponse(userInfo: ["sessionId": "application"]) {
            responseCompleted = true
        }

        #expect(counters.delegateInstalls == 1)
        #expect(counters.metricStarts == 1)
        #expect(counters.tokens == ["01af"])
        #expect(counters.failures == 1)
        #expect(counters.tokenLogs == 1)
        #expect(counters.failureLogs == 1)
        #expect(presentationOptions == [.banner, .sound])
        #expect(responseCompleted)
        #expect(counters.navigations == 1)
    }

    @Test("default delegate resolves hosted mode in the injected unit-test host")
    func defaultDelegateIsHosted() {
        let delegate = AppDelegate()
        #expect(delegate.runtimeMode == .hostedUnitTests)
    }
}
