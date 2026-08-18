import Testing
@testable import TronMobile

@Suite("Queued message presentation policy")
struct QueuedMessagePresentationTests {
    @Test("queue editing requires authoritative rich state")
    func managementAvailability() {
        #expect(QueuedMessageManagementPolicy.availability(
            capabilities: [QueuedMessageManagementPolicy.capability],
            queueRevision: 4,
            hasAuthoritativeItems: true
        ) == .available)
        #expect(QueuedMessageManagementPolicy.availability(
            capabilities: [QueuedMessageManagementPolicy.capability],
            queueRevision: nil,
            hasAuthoritativeItems: true
        ) == .invalidProjection)
        #expect(QueuedMessageManagementPolicy.availability(
            capabilities: [QueuedMessageManagementPolicy.capability],
            queueRevision: 4,
            hasAuthoritativeItems: false
        ) == .invalidProjection)
        #expect(QueuedMessageManagementPolicy.availability(
            capabilities: [],
            queueRevision: nil,
            hasAuthoritativeItems: false
        ) == .requiresGatewayUpdate)
    }

    @Test("only authoritative rich queue state permits mutation")
    func mutationGate() {
        #expect(QueuedMessageManagementAvailability.available.isManageable)
        #expect(!QueuedMessageManagementAvailability.requiresGatewayUpdate.isManageable)
        #expect(!QueuedMessageManagementAvailability.invalidProjection.isManageable)
    }
}
