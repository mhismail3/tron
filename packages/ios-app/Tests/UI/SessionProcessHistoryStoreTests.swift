import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Session process history presentation suspension")
struct SessionProcessHistoryStoreTests {
    @Test("returning from a child cannot replay an exhausted first page", arguments: [false, true])
    func exhaustedPageSurvivesChildRoundTrip(empty: Bool) async throws {
        let gateway = ProcessSheetGatewayFixture()
        try await gateway.connect()
        let store = SessionProcessHistoryStore(client: gateway.client)
        store.reset(sessionID: "session", presentationGeneration: 7)
        store.loadNext(sessionID: "session", presentationGeneration: 7)
        try await gateway.respond(at: 1, method: "session.processHistory.list", result: ProcessSheetGatewayFixture.history(ids: empty ? [] : ["worker"]))
        try await settled(store)
        #expect(store.status == .loaded)
        #expect(store.nextCursor == nil)
        let retained = store.processes

        store.suspendPendingWork()
        store.loadInitialPageIfNeeded(sessionID: "session", presentationGeneration: 7)
        store.loadNext(sessionID: "session", presentationGeneration: 7)
        #expect(store.status == .loaded)
        #expect(!store.hostedHasPendingPage)
        #expect(store.processes == retained)
        store.suspendPendingWork()
        await gateway.client.close()
    }

    @Test("revealing history preserves its cursor until explicit Load More")
    func revealingDoesNotAdvancePagination() async throws {
        let gateway = ProcessSheetGatewayFixture()
        try await gateway.connect()
        let store = SessionProcessHistoryStore(client: gateway.client)
        store.reset(sessionID: "session", presentationGeneration: 7)
        store.loadInitialPageIfNeeded(sessionID: "session", presentationGeneration: 7)
        try await gateway.respond(at: 1, method: "session.processHistory.list", result: ProcessSheetGatewayFixture.history(next: "page-2"))
        try await settled(store)
        store.suspendPendingWork()
        store.loadInitialPageIfNeeded(sessionID: "session", presentationGeneration: 7)
        #expect(store.status == .loaded)
        #expect(!store.hostedHasPendingPage)
        #expect(store.nextCursor == "page-2")
        #expect(store.processes.map(\.processId) == ["worker"])

        store.loadNext(sessionID: "session", presentationGeneration: 7)
        try await gateway.respond(at: 2, method: "session.processHistory.list", result: ProcessSheetGatewayFixture.history(ids: ["older"]))
        try await settled(store)
        #expect(store.status == .loaded)
        #expect(Set(store.processes.map(\.processId)) == ["worker", "older"])
        #expect(store.nextCursor == nil)
        await gateway.client.close()
    }

    @Test("a genuine revision conflict still rejects mixed history pages")
    func changedRevisionIsNotSilentlyAppended() async throws {
        let gateway = ProcessSheetGatewayFixture()
        try await gateway.connect()
        let store = SessionProcessHistoryStore(client: gateway.client)
        store.reset(sessionID: "session", presentationGeneration: 7)
        store.loadNext(sessionID: "session", presentationGeneration: 7)
        try await gateway.respond(at: 1, method: "session.processHistory.list", result: ProcessSheetGatewayFixture.history(next: "page-2"))
        try await settled(store)
        store.loadNext(sessionID: "session", presentationGeneration: 7)
        try await gateway.respond(at: 2, method: "session.processHistory.list", result: ProcessSheetGatewayFixture.history(ids: ["older"], revision: "history-2"))
        try await settled(store)
        #expect(store.status == .conflict)
        #expect(store.processes.map(\.processId) == ["worker"])
        #expect(store.historyRevision == "history-1")
        await gateway.client.close()
    }

    private func settled(_ store: SessionProcessHistoryStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.hostedHasPendingPage, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.hostedHasPendingPage)
    }

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
