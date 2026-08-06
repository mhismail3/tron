import XCTest
@testable import TronMobile

@MainActor
final class ChatViewModelCachedTranscriptTests: XCTestCase {

    func testSuccessfulReconstructionWarmsNextPresentationCache() async throws {
        let testState = IsolatedTestState(label: "cached-transcript")
        testState.registerTeardown(with: self)
        let database = testState.makeDatabase()
        try await database.initialize()

        let engineClient = EngineClient(
            serverURL: URL(string: "ws://localhost:8080/engine")!
        )
        let manager = EventStoreManager(
            eventDB: database,
            engineClient: engineClient,
            defaults: testState.defaults
        )
        addTeardownBlock {
            await manager.shutdown()
        }

        let writer = ChatViewModel(
            engineClient: engineClient,
            sessionId: "cached-session",
            eventStoreManager: manager
        )
        await writer.processReconstructionResult(
            reconstructionResult(content: "cached hello")
        )
        XCTAssertEqual(writer.sessionLoadDiagnostics.snapshot.authoritativeEventCount, 1)
        XCTAssertEqual(writer.sessionLoadDiagnostics.snapshot.authoritativeMessageCount, 1)
        XCTAssertEqual(writer.conversationHistoryPhase, .authoritative)
        XCTAssertNotNil(writer.sessionLoadDiagnostics.snapshot.interactiveMs)

        let cachedEvents = try await database.events.getBySession("cached-session")
        XCTAssertEqual(cachedEvents.map(\.id), ["cached-user-message"])

        let reader = ChatViewModel(
            engineClient: engineClient,
            sessionId: "cached-session",
            eventStoreManager: manager
        )
        let restored = await reader.restoreCachedTranscript()

        XCTAssertTrue(restored)
        XCTAssertEqual(reader.sessionLoadDiagnostics.snapshot.cacheHit, true)
        XCTAssertEqual(reader.sessionLoadDiagnostics.snapshot.cachedEventCount, 1)
        XCTAssertEqual(reader.sessionLoadDiagnostics.snapshot.cachedMessageCount, 1)
        XCTAssertEqual(reader.conversationHistoryPhase, .cachedSynchronizing)
        XCTAssertFalse(reader.hasAuthoritativeHistory)
        XCTAssertEqual(reader.messages.count, 1)
        guard case .text(let content) = reader.messages.first?.content else {
            return XCTFail("Expected cached text message")
        }
        XCTAssertEqual(content, "cached hello")
    }

    func testMissingCacheKeepsPresentationInPendingState() async throws {
        let testState = IsolatedTestState(label: "missing-cached-transcript")
        testState.registerTeardown(with: self)
        let database = testState.makeDatabase()
        try await database.initialize()

        let engineClient = EngineClient(
            serverURL: URL(string: "ws://localhost:8080/engine")!
        )
        let manager = EventStoreManager(
            eventDB: database,
            engineClient: engineClient,
            defaults: testState.defaults
        )
        addTeardownBlock {
            await manager.shutdown()
        }
        let viewModel = ChatViewModel(
            engineClient: engineClient,
            sessionId: "uncached-session",
            eventStoreManager: manager
        )

        let restored = await viewModel.restoreCachedTranscript()
        XCTAssertFalse(restored)
        XCTAssertEqual(viewModel.sessionLoadDiagnostics.snapshot.cacheHit, false)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.conversationHistoryPhase, .loading)
    }

    func testDelayedCachedReconstructionRetainsDraftPresentationWithoutBecomingAuthoritative() async throws {
        let testState = IsolatedTestState(label: "delayed-cached-transcript")
        testState.registerTeardown(with: self)
        let database = testState.makeDatabase()
        try await database.initialize()
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let manager = EventStoreManager(
            eventDB: database,
            engineClient: engineClient,
            defaults: testState.defaults
        )
        addTeardownBlock { await manager.shutdown() }
        let writer = ChatViewModel(
            engineClient: engineClient,
            sessionId: "cached-session",
            eventStoreManager: manager
        )
        await writer.processReconstructionResult(reconstructionResult(content: "cached hello"))
        let reader = ChatViewModel(
            engineClient: engineClient,
            sessionId: "cached-session",
            eventStoreManager: manager
        )

        let restored = await reader.restoreCachedTranscript()
        XCTAssertTrue(restored)
        reader.markInitialReconstructionDelayed()

        XCTAssertEqual(
            reader.conversationHistoryPhase,
            .recoverableFailure(hasCachedTranscript: true)
        )
        XCTAssertTrue(reader.conversationHistoryPhase.allowsDraftEditing)
        XCTAssertFalse(reader.hasAuthoritativeHistory)
    }

    func testReconnectFailurePreservesCommittedAuthoritativeHistory() async throws {
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let viewModel = ChatViewModel(
            engineClient: engineClient,
            sessionId: "authoritative-session"
        )
        viewModel.conversationHistoryPhase = .authoritative

        viewModel.recordReconstructionOutcome(.retryableFailure)

        XCTAssertEqual(viewModel.conversationHistoryPhase, .authoritative)
        XCTAssertTrue(viewModel.conversationHistoryPhase.allowsDraftEditing)
    }

    private func reconstructionResult(content: String) -> SessionReconstructResult {
        let event = RawEvent(
            id: "cached-user-message",
            parentId: nil,
            sessionId: "cached-session",
            workspaceId: "/test/workspace",
            type: SessionEventType.messageUser.rawValue,
            timestamp: "2026-08-03T00:00:00Z",
            sequence: 1,
            payload: ["content": AnyCodable(content)]
        )
        return SessionReconstructResult(
            events: [event],
            hasMoreEvents: false,
            oldestEventId: event.id,
            inFlight: nil,
            lastSequence: 1,
            isRunning: false,
            isCompacting: false,
            compactionReason: nil,
            agentPhase: "idle",
            metadata: ReconstructMetadata(
                model: nil,
                turnCount: 1,
                workingDirectory: nil,
                title: nil,
                tokenUsage: nil,
                totalCost: nil
            )
        )
    }
}
