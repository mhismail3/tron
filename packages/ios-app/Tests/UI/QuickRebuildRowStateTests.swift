import Testing
@testable import TronMobile

@Suite("Quick rebuild row state")
struct QuickRebuildRowStateTests {
    @Test("rows are ready only when supported, configured, and idle")
    func availability() {
        #expect(QuickRebuildRowState.gateway(supported: true, configured: true, active: false) == .ready)
        #expect(QuickRebuildRowState.gateway(supported: true, configured: true, active: true) == .running)
        #expect(QuickRebuildRowState.gateway(supported: true, configured: false, active: false)
            == .unavailable("Set a source repository in server details"))
        #expect(QuickRebuildRowState.gateway(supported: false, configured: true, active: true)
            == .unavailable("Not supported by this Gateway"))
        #expect(QuickRebuildRowState.device(supported: true, configured: true, active: false) == .ready)
        #expect(QuickRebuildRowState.device(supported: true, configured: false, active: true) == .running,
                "an install already running stays visible even if configuration reads lag")
        #expect(QuickRebuildRowState.device(supported: true, configured: false, active: false)
            == .unavailable("Set a source repository in device details"))
    }
}
