import Foundation
import Testing

@testable import TronMobile

@Suite("Engine connection continuity")
struct ChatConnectionContinuityTests {
    @Test("a normal connected edge requests recovery")
    func connectedEdgeRequestsRecovery() {
        let old = EngineConnectionContinuity(
            state: .disconnected,
            generation: 0
        )
        let new = EngineConnectionContinuity(
            state: .connected,
            generation: 1
        )

        #expect(new.requiresReconciliation(after: old))
    }

    @Test("a connected transport-generation edge requests recovery")
    func collapsedReconnectRequestsRecovery() {
        let old = EngineConnectionContinuity(
            state: .connected,
            generation: 4
        )
        let new = EngineConnectionContinuity(
            state: .connected,
            generation: 5
        )

        #expect(new.requiresReconciliation(after: old))
    }

    @Test("ordinary connected observation is idempotent")
    func unchangedConnectionDoesNotRequestRecovery() {
        let continuity = EngineConnectionContinuity(
            state: .connected,
            generation: 5
        )

        #expect(!continuity.requiresReconciliation(after: continuity))
    }

    @Test("a replacement client requests recovery even when its local generation matches")
    func replacementOwnerRequestsRecovery() {
        let old = EngineConnectionContinuity(
            state: .connected,
            generation: 1,
            ownerId: UUID()
        )
        let new = EngineConnectionContinuity(
            state: .connected,
            generation: 1,
            ownerId: UUID()
        )

        #expect(new.requiresReconciliation(after: old))
    }
}
