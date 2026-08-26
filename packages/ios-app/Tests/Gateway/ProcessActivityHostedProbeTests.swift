import Testing
@testable import TronMobile

#if HOSTED_TEST
@MainActor
@Suite("Process activity hosted probe")
struct ProcessActivityHostedProbeTests {
    @Test("process routing records one session-level destination")
    func processRoute() {
        let probe = ChatHostedProbe()
        probe.recordProcessRoute()
        #expect(probe.observation.processRoutes == ["processes"])
    }
}
#endif
