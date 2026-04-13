import XCTest
@testable import TronMobile

@MainActor
final class CompactionCoordinatorTests: XCTestCase {

    private var coordinator: CompactionCoordinator!
    private var mockContext: MockCompactionContext!

    override func setUp() async throws {
        coordinator = CompactionCoordinator()
        mockContext = MockCompactionContext()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - handleCompactionStarted Tests

    func testCompactionStartedSetsIsCompacting() {
        let result = CompactionStartedPlugin.Result(reason: "auto")
        coordinator.handleCompactionStarted(result, context: mockContext)

        XCTAssertTrue(mockContext.isCompacting)
    }

    func testCompactionStartedFinalizesStreaming() {
        let result = CompactionStartedPlugin.Result(reason: "auto")
        coordinator.handleCompactionStarted(result, context: mockContext)

        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testCompactionStartedAppendsInProgressMessage() {
        let result = CompactionStartedPlugin.Result(reason: "auto")
        coordinator.handleCompactionStarted(result, context: mockContext)

        XCTAssertEqual(mockContext.messages.count, 1)
        if case .systemEvent(.compactionInProgress) = mockContext.messages[0].content {
            // correct
        } else {
            XCTFail("Expected compactionInProgress content, got \(mockContext.messages[0].content)")
        }
    }

    func testCompactionStartedTracksInProgressMessageId() {
        let result = CompactionStartedPlugin.Result(reason: "auto")
        coordinator.handleCompactionStarted(result, context: mockContext)

        XCTAssertNotNil(mockContext.compactionInProgressMessageId)
        XCTAssertEqual(mockContext.compactionInProgressMessageId, mockContext.messages[0].id)
    }

    // MARK: - handleCompaction Tests

    func testCompactionClearsIsCompacting() {
        mockContext.isCompacting = true

        let result = makeCompactionResult(tokensBefore: 10000, tokensAfter: 5000)
        coordinator.handleCompaction(result, context: mockContext)

        XCTAssertFalse(mockContext.isCompacting)
    }

    func testCompactionFinalizesStreaming() {
        let result = makeCompactionResult(tokensBefore: 10000, tokensAfter: 5000)
        coordinator.handleCompaction(result, context: mockContext)

        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testCompactionUpdatesContextTokens() {
        let result = makeCompactionResult(tokensBefore: 10000, tokensAfter: 5000)
        coordinator.handleCompaction(result, context: mockContext)

        XCTAssertEqual(mockContext.contextState.lastTurnInputTokens, 5000)
    }

    func testCompactionPrefersEstimatedContextTokens() {
        let result = makeCompactionResult(tokensBefore: 10000, tokensAfter: 5000, estimatedContextTokens: 7000)
        coordinator.handleCompaction(result, context: mockContext)

        XCTAssertEqual(mockContext.contextState.lastTurnInputTokens, 7000)
    }

    func testCompactionMutatesInProgressPillInPlace() {
        // Set up in-progress pill
        let inProgressMsg = ChatMessage.compactionInProgress(reason: "auto")
        mockContext.appendToMessages(inProgressMsg)
        mockContext.compactionInProgressMessageId = inProgressMsg.id

        let result = makeCompactionResult(tokensBefore: 10000, tokensAfter: 5000)
        coordinator.handleCompaction(result, context: mockContext)

        // Should mutate in-place (same message count)
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .systemEvent(.compaction(let before, let after, _, _, _, _)) = mockContext.messages[0].content {
            XCTAssertEqual(before, 10000)
            XCTAssertEqual(after, 5000)
        } else {
            XCTFail("Expected compaction content")
        }
        XCTAssertNil(mockContext.compactionInProgressMessageId)
    }

    func testCompactionAppendsWhenNoInProgressPill() {
        let result = makeCompactionResult(tokensBefore: 10000, tokensAfter: 5000)
        coordinator.handleCompaction(result, context: mockContext)

        XCTAssertEqual(mockContext.messages.count, 1)
        if case .systemEvent(.compaction) = mockContext.messages[0].content {
            // correct
        } else {
            XCTFail("Expected compaction content")
        }
    }

    func testCompactionRefreshesContextInBackground() {
        let result = makeCompactionResult(tokensBefore: 10000, tokensAfter: 5000)
        coordinator.handleCompaction(result, context: mockContext)

        XCTAssertTrue(mockContext.refreshContextInBackgroundCalled)
    }

    func testCompactionThenRefreshOverwritesEstimate() {
        // Compaction sets estimatedContextTokens
        let result = makeCompactionResult(tokensBefore: 66000, tokensAfter: 18000, estimatedContextTokens: 29000)
        coordinator.handleCompaction(result, context: mockContext)

        XCTAssertEqual(mockContext.contextState.lastTurnInputTokens, 29000)

        // refreshContextInBackground would call syncFromServerSnapshot
        // Simulate server returning the true post-compaction context size
        mockContext.contextState.syncFromServerSnapshot(currentTokens: 77300, contextLimit: 1_000_000)

        XCTAssertEqual(mockContext.contextState.contextWindowTokens, 77300)
    }

    // MARK: - Helpers

    private func makeCompactionResult(
        tokensBefore: Int,
        tokensAfter: Int,
        estimatedContextTokens: Int? = nil
    ) -> CompactionPlugin.Result {
        CompactionPlugin.Result(
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            compressionRatio: Double(tokensAfter) / Double(tokensBefore),
            reason: "auto",
            summary: "Summarized conversation",
            estimatedContextTokens: estimatedContextTokens,
            preservedTurns: 3,
            summarizedTurns: 5
        )
    }
}

// MARK: - Mock Context

@MainActor
final class MockCompactionContext: CompactionContext {
    var isCompacting = false
    var compactionInProgressMessageId: UUID?
    let contextState = ContextTrackingState()
    var messages: [ChatMessage] = []
    let messageIndex = MessageIndex()

    var flushPendingTextUpdatesCalled = false
    var finalizeStreamingMessageCalled = false
    var resetStreamingManagerCalled = false
    var refreshContextInBackgroundCalled = false

    func flushPendingTextUpdates() {
        flushPendingTextUpdatesCalled = true
    }

    func finalizeStreamingMessage() {
        finalizeStreamingMessageCalled = true
    }

    func resetStreamingManager() {
        resetStreamingManagerCalled = true
    }

    func refreshContextInBackground() {
        refreshContextInBackgroundCalled = true
    }

    // MARK: - LoggingContext

    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
    func showError(_ message: String) {}
}
