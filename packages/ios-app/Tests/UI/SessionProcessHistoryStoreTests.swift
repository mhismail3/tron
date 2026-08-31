import Testing
@testable import TronMobile

@MainActor
@Suite("Session process history presentation suspension")
struct SessionProcessHistoryStoreTests {
    @Test("cover suspension cancels pending page work without discarding ownership")
    func suspensionCancelsPendingPage() {
        let store = SessionProcessHistoryStore(client: GatewayClient())
        store.installHostedPendingPage(
            sessionID: "session",
            presentationGeneration: 7
        )
        #expect(store.status == .loading)
        #expect(store.hostedHasPendingPage)

        store.suspendPendingWork()

        #expect(!store.hostedHasPendingPage)
        #expect(store.status == .idle)
        #expect(store.sessionID == "session")
        #expect(store.presentationGeneration == 7)
        #expect(store.processes.isEmpty)
    }
}
