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
        viewModel.isProcessing = true

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
           case .compaction(let before, let after, _, _, _, _, _) = event {
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
