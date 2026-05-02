import Testing
import Foundation

@testable import TronMobile

@Suite("ReconnectProbePolicy")
struct ReconnectProbePolicyTests {

    @Test("default policy uses one two-second automatic probe")
    func defaultConstants() {
        let policy = ReconnectProbePolicy()
        #expect(policy.maxAutomaticAttempts == 1)
        #expect(policy.probeTimeout == 2.0)
    }

    @Test("custom policy stores explicit values")
    func customPolicy() {
        let policy = ReconnectProbePolicy(maxAutomaticAttempts: 2, probeTimeout: 1.5)
        #expect(policy.maxAutomaticAttempts == 2)
        #expect(policy.probeTimeout == 1.5)
    }
}
