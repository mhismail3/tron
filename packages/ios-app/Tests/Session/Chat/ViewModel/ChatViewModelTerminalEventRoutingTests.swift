import XCTest
@testable import TronMobile

@MainActor
final class ChatViewModelTerminalEventRoutingTests: XCTestCase {
    private var viewModel: ChatViewModel!

    override func setUp() async throws {
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        viewModel = ChatViewModel(
            engineClient: engineClient,
            sessionId: "test-session-\(UUID().uuidString)",
            eventStoreManager: nil
        )
    }

    override func tearDown() async throws {
        viewModel = nil
    }

    func test_agentError_addsErrorMessageToMessages() {
        let initialCount = viewModel.messages.count

        viewModel.handleAgentError("Something went wrong")

        XCTAssertEqual(viewModel.messages.count, initialCount + 1)
        if let lastMessage = viewModel.messages.last,
           case .error(let errorText) = lastMessage.content {
            XCTAssertEqual(errorText, "Something went wrong")
        } else {
            XCTFail("Expected error message")
        }
    }

    func test_agentError_stopsProcessing() {
        viewModel.agentPhase = .processing

        viewModel.handleAgentError("Error occurred")

        XCTAssertFalse(viewModel.isProcessing)
    }

    func test_compaction_addsNotificationMessage() {
        let initialCount = viewModel.messages.count

        viewModel.handleCompaction(makeCompactionResult(
            tokensBefore: 100_000,
            tokensAfter: 50_000,
            reason: "context_limit",
            summary: "Summarized previous messages"
        ))

        XCTAssertEqual(viewModel.messages.count, initialCount + 1)
        if let lastMessage = viewModel.messages.last,
           case .systemEvent(let event) = lastMessage.content,
           case .compaction(let before, let after, _, _, _, _) = event {
            XCTAssertEqual(before, 100_000)
            XCTAssertEqual(after, 50_000)
        } else {
            XCTFail("Expected compaction notification message")
        }
    }

    func test_compaction_updatesContextState() {
        viewModel.handleCompaction(makeCompactionResult(
            tokensBefore: 100_000,
            tokensAfter: 50_000,
            reason: "context_limit"
        ))

        XCTAssertEqual(viewModel.contextState.lastTurnInputTokens, 50_000)
    }

    func test_agentReady_setsIdlePhase() {
        viewModel.agentPhase = .processing

        viewModel.handleAgentReady()

        XCTAssertEqual(viewModel.agentPhase, .idle)
    }

    func test_cancelledTurnWaitsForCompleteBeforeFinalizingOnce() {
        viewModel.agentPhase = .stopping
        viewModel.handleTurnStart(TurnStartPlugin.Result(turnNumber: 1, agentPhase: "processing"))
        XCTAssertEqual(viewModel.agentPhase, .stopping)
        viewModel.handleTextDelta("Partial response before cancellation")

        viewModel.handleTurnFailed(makeCancelledTurnResult())

        XCTAssertEqual(viewModel.agentPhase, .stopping)
        XCTAssertEqual(
            viewModel.messages.filter {
                if case .systemEvent(.interrupted) = $0.content { return true }
                return false
            }.count,
            1
        )

        viewModel.handleComplete()

        XCTAssertEqual(viewModel.agentPhase, .idle)
        XCTAssertFalse(viewModel.messages.contains(where: \.isStreaming))
        XCTAssertTrue(viewModel.currentTurnToolMessageIds.isEmpty)
    }

    private func makeCancelledTurnResult() -> TurnFailedPlugin.Result {
        let failure = CanonicalFailurePayload(
            code: "RUNTIME_CANCELLED",
            category: "cancelled",
            message: "Interrupted by user",
            retryable: false,
            recoverable: true,
            origin: "agent_runtime"
        )
        return TurnFailedPlugin.Result(
            turn: 1,
            error: failure.message,
            code: failure.code,
            category: failure.category,
            retryable: failure.retryable,
            recoverable: failure.recoverable,
            origin: failure.origin,
            details: nil,
            failure: failure,
            partialContent: "Partial response before cancellation"
        )
    }

    private func makeCompactionResult(
        success: Bool = true,
        tokensBefore: Int,
        tokensAfter: Int,
        reason: String,
        summary: String? = nil
    ) -> CompactionPlugin.Result {
        let ratio = tokensBefore > 0 ? Double(tokensAfter) / Double(tokensBefore) : 1.0
        return CompactionPlugin.Result(
            success: success,
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            compressionRatio: ratio,
            reason: reason,
            summary: summary,
            estimatedContextTokens: nil,
            preservedTurns: nil,
            summarizedTurns: nil
        )
    }
}
