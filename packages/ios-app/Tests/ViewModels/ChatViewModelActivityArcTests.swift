import XCTest
@testable import TronMobile

/// Tests for ChatViewModel.shouldShowActivityArc computed property.
/// Arc shows whenever agent is not idle (processing or postProcessing).
@MainActor
final class ChatViewModelActivityArcTests: XCTestCase {

    var viewModel: ChatViewModel!

    override func setUp() async throws {
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        viewModel = ChatViewModel(rpcClient: rpcClient, sessionId: "test-session")
    }

    override func tearDown() async throws {
        viewModel = nil
    }

    // MARK: - Hidden when idle

    func testArcHiddenWhenIdle() {
        viewModel.agentPhase = .idle
        XCTAssertFalse(viewModel.shouldShowActivityArc)
    }

    // MARK: - Shown during processing (regardless of streaming/subagents/thinking)

    func testArcShownWhenProcessing() {
        viewModel.agentPhase = .processing
        XCTAssertTrue(viewModel.shouldShowActivityArc)
    }

    func testArcShownWhileStreaming() {
        viewModel.agentPhase = .processing
        viewModel.messages = [ChatMessage.streaming()]
        XCTAssertTrue(viewModel.shouldShowActivityArc)
    }

    func testArcShownWithSubagents() {
        viewModel.agentPhase = .processing
        viewModel.subagentState.trackSpawn(toolCallId: "tc-1", subagentSessionId: "sub-1", task: "test", model: nil)
        XCTAssertTrue(viewModel.shouldShowActivityArc)
    }

    func testArcShownWithThinking() {
        viewModel.agentPhase = .processing
        viewModel.thinkingMessageId = UUID()
        XCTAssertTrue(viewModel.shouldShowActivityArc)
    }

    // MARK: - Shown during postProcessing

    func testArcShownWhenPostProcessing() {
        viewModel.agentPhase = .postProcessing
        XCTAssertTrue(viewModel.shouldShowActivityArc)
    }
}
