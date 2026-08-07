import Testing

@testable import TronMobile

@Suite("Chat connection continuity")
struct ChatConnectionContinuityTests {
    @Test("a normal connected edge requests recovery")
    func connectedEdgeRequestsRecovery() {
        let old = ChatConnectionContinuity(
            state: .disconnected,
            generation: 0
        )
        let new = ChatConnectionContinuity(
            state: .connected,
            generation: 1
        )

        #expect(new.requiresRecovery(after: old))
    }

    @Test("a connected transport-generation edge requests recovery")
    func collapsedReconnectRequestsRecovery() {
        let old = ChatConnectionContinuity(
            state: .connected,
            generation: 4
        )
        let new = ChatConnectionContinuity(
            state: .connected,
            generation: 5
        )

        #expect(new.requiresRecovery(after: old))
    }

    @Test("ordinary connected observation is idempotent")
    func unchangedConnectionDoesNotRequestRecovery() {
        let continuity = ChatConnectionContinuity(
            state: .connected,
            generation: 5
        )

        #expect(!continuity.requiresRecovery(after: continuity))
    }
}
