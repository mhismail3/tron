#if HOSTED_TEST
import Testing
@testable import TronMobile

@MainActor
@Suite("Extension activity hosted instrumentation")
struct ExtensionActivityHostedProbeTests {
    @Test("probe records only typed pill state, route, and expiry")
    func recordsOpaquePillSignals() {
        let probe = ChatHostedProbe()
        let state = ExtensionActivityPillVisualState(
            ownerID: "owner:test", title: "Test", detail: "1 running",
            symbol: "circle.dotted", tone: .warning, count: 2,
            showsProgress: true, accessibilityLabel: "Extension Test, 1 running, 2 items"
        )
        probe.recordExtensionPillState(state, transitionToken: 4)
        probe.recordExtensionRoute("owner:test")
        probe.recordExtensionPillExpiry(ownerID: "owner:test", bucket: .recent, remainingMs: 500)

        let observation = probe.observation
        #expect(observation.extensionPillStates == [
            ExtensionActivityPillHostedSample(ownerID: "owner:test", detail: "1 running", count: 2, transitionToken: 4)
        ])
        #expect(observation.extensionRoutes == ["owner:test"])
        #expect(observation.extensionPillExpiries == [
            ExtensionActivityPillExpirySample(ownerID: "owner:test", bucket: .recent, remainingMs: 500)
        ])
    }
}
#endif
