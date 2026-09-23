import Foundation
import Testing
@testable import TronMobile

struct GatewayRecoveryPolicyTests {
    @Test("reconnect delay grows exponentially and caps before jitter")
    func reconnectDelayIsCapped() {
        let policy = ReconnectDelayPolicy(
            initialSeconds: 2,
            multiplier: 1.7,
            maximumSeconds: 15,
            jitterFraction: 0.2,
            nextUnitInterval: { 1 }
        )
        #expect(policy.delay(nominalSeconds: 2) == .seconds(2.4))
        #expect(policy.nextNominalSeconds(after: 2) == 3.4)
        #expect(policy.delay(nominalSeconds: 15) == .seconds(15))
        #expect(policy.nextNominalSeconds(after: 15) == 15)
    }

    @Test("only permanent connection admission failures stop recovery")
    func nonRetryableClassification() {
        for code in ["unauthenticated", "forbidden", "protocol_mismatch", "identity_mismatch"] {
            #expect(GatewayRecoveryFailurePolicy.isNonRetryable(
                GatewayFailure(code: code, message: code, retryable: true, details: nil)
            ))
        }
        #expect(!GatewayRecoveryFailurePolicy.isNonRetryable(
            GatewayFailure(code: "unavailable", message: "temporary", retryable: true, details: nil)
        ))
    }
}
