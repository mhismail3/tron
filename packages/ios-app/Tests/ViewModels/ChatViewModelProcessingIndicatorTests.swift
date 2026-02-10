import XCTest
@testable import TronMobile

/// Tests for ChatViewModel.shouldShowProcessingIndicator and shouldShowBreathingLine.
///
/// The breathing line ("Processing...") appears only when the model is actively
/// thinking and NO other visual feedback is present: no text streaming, no thinking
/// block streaming, no tool spinner, no subagent chip.
@MainActor
final class ChatViewModelProcessingIndicatorTests: XCTestCase {

    var viewModel: ChatViewModel!

    override func setUp() async throws {
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        viewModel = ChatViewModel(rpcClient: rpcClient, sessionId: "test-session")
    }

    override func tearDown() async throws {
        viewModel = nil
    }

    // MARK: - shouldShowProcessingIndicator (scroll anchor)

    func testIndicatorHiddenWhenIdle() {
        viewModel.agentPhase = .idle
        XCTAssertFalse(viewModel.shouldShowProcessingIndicator)
    }

    func testIndicatorShownWhenProcessing() {
        viewModel.agentPhase = .processing
        XCTAssertTrue(viewModel.shouldShowProcessingIndicator)
    }

    func testIndicatorShownWhenPostProcessing() {
        viewModel.agentPhase = .postProcessing
        XCTAssertTrue(viewModel.shouldShowProcessingIndicator)
    }

    // MARK: - shouldShowBreathingLine: idle and postProcessing → hidden

    func testBreathingLineHiddenWhenIdle() {
        viewModel.agentPhase = .idle
        XCTAssertFalse(viewModel.shouldShowBreathingLine)
    }

    func testBreathingLineHiddenWhenPostProcessing() {
        viewModel.agentPhase = .postProcessing
        XCTAssertFalse(viewModel.shouldShowBreathingLine)
    }

    // MARK: - shouldShowBreathingLine: the "gap" states → shown

    func testBreathingLineShownBeforeFirstEvent() {
        // User sent message, waiting for first thinking/text/tool event
        viewModel.agentPhase = .processing
        XCTAssertTrue(viewModel.shouldShowBreathingLine)
    }

    func testBreathingLineShownAfterThinkingEnds() {
        // Thinking finished streaming, model deciding what to do next
        viewModel.agentPhase = .processing
        let thinking = ChatMessage.thinking("some thought", isStreaming: false)
        viewModel.messages = [thinking]
        viewModel.thinkingMessageId = thinking.id
        XCTAssertTrue(viewModel.shouldShowBreathingLine)
    }

    func testBreathingLineShownAfterToolCompletes() {
        // Tool finished, model deciding next action
        viewModel.agentPhase = .processing
        let tool = makeToolMessage(status: .success)
        viewModel.messages = [tool]
        viewModel.currentToolMessages = [tool.id: tool]
        XCTAssertTrue(viewModel.shouldShowBreathingLine)
    }

    // MARK: - shouldShowBreathingLine: active feedback → hidden

    func testBreathingLineHiddenDuringTextStreaming() {
        viewModel.agentPhase = .processing
        viewModel.messages = [ChatMessage.streaming("hello")]
        XCTAssertFalse(viewModel.shouldShowBreathingLine)
    }

    func testBreathingLineHiddenDuringThinkingStreaming() {
        viewModel.agentPhase = .processing
        let thinking = ChatMessage.thinking("pondering...", isStreaming: true)
        viewModel.messages = [thinking]
        viewModel.thinkingMessageId = thinking.id
        XCTAssertFalse(viewModel.shouldShowBreathingLine)
    }

    func testBreathingLineHiddenDuringToolExecution() {
        viewModel.agentPhase = .processing
        let tool = makeToolMessage(status: .running)
        viewModel.messages = [tool]
        viewModel.currentToolMessages = [tool.id: tool]
        XCTAssertFalse(viewModel.shouldShowBreathingLine)
    }

    func testBreathingLineHiddenDuringSubagentExecution() {
        viewModel.agentPhase = .processing
        viewModel.subagentState.trackSpawn(
            toolCallId: "tc-1", subagentSessionId: "sub-1", task: "test", model: nil
        )
        XCTAssertFalse(viewModel.shouldShowBreathingLine)
    }

    // MARK: - shouldShowBreathingLine: mixed states

    func testBreathingLineHiddenWhenOneToolRunningOneComplete() {
        // Two tools: one done, one still running → tool spinner visible
        viewModel.agentPhase = .processing
        let done = makeToolMessage(status: .success)
        let running = makeToolMessage(status: .running)
        viewModel.messages = [done, running]
        viewModel.currentToolMessages = [done.id: done, running.id: running]
        XCTAssertFalse(viewModel.shouldShowBreathingLine)
    }

    func testBreathingLineShownWhenAllToolsComplete() {
        // Two tools both done → no spinner, model is thinking
        viewModel.agentPhase = .processing
        let done1 = makeToolMessage(status: .success)
        let done2 = makeToolMessage(status: .success)
        viewModel.messages = [done1, done2]
        viewModel.currentToolMessages = [done1.id: done1, done2.id: done2]
        XCTAssertTrue(viewModel.shouldShowBreathingLine)
    }

    // MARK: - Helpers

    private func makeToolMessage(status: ToolStatus) -> ChatMessage {
        let tool = ToolUseData(
            toolName: "Read",
            toolCallId: UUID().uuidString,
            arguments: "{}",
            status: status,
            result: status == .running ? nil : "ok"
        )
        return ChatMessage(role: .assistant, content: .toolUse(tool))
    }
}
