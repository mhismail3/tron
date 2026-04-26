import Testing
@testable import TronMobile

@Suite("ConnectionPresetRemoval")
struct ConnectionPresetRemovalTests {
    private func preset(
        id: String,
        host: String,
        port: Int = 9847
    ) -> ConnectionPreset {
        ConnectionPreset(id: id, label: id, host: host, port: port)
    }

    @Test("removing inactive preset keeps active server and does not return to onboarding")
    func removingInactivePresetKeepsCurrentServer() {
        let active = preset(id: "active", host: "100.64.0.1")
        let inactive = preset(id: "inactive", host: "100.64.0.2")

        let plan = ConnectionPresetRemoval.plan(
            removing: inactive,
            from: [active, inactive],
            activeHost: active.host,
            activePort: String(active.port)
        )

        #expect(plan.updatedPresets == [active])
        #expect(plan.removedWasActive == false)
        #expect(plan.nextActivePreset == nil)
        #expect(plan.shouldReturnToOnboarding == false)
    }

    @Test("removing active preset selects the next saved server")
    func removingActivePresetSelectsNextServer() {
        let active = preset(id: "active", host: "100.64.0.1")
        let next = preset(id: "next", host: "100.64.0.2")

        let plan = ConnectionPresetRemoval.plan(
            removing: active,
            from: [active, next],
            activeHost: active.host,
            activePort: String(active.port)
        )

        #expect(plan.updatedPresets == [next])
        #expect(plan.removedWasActive == true)
        #expect(plan.nextActivePreset == next)
        #expect(plan.shouldReturnToOnboarding == false)
    }

    @Test("removing final preset returns to onboarding")
    func removingFinalPresetReturnsToOnboarding() {
        let only = preset(id: "only", host: "100.64.0.1")

        let plan = ConnectionPresetRemoval.plan(
            removing: only,
            from: [only],
            activeHost: only.host,
            activePort: String(only.port)
        )

        #expect(plan.updatedPresets.isEmpty)
        #expect(plan.removedWasActive == true)
        #expect(plan.nextActivePreset == nil)
        #expect(plan.shouldReturnToOnboarding == true)
    }
}
