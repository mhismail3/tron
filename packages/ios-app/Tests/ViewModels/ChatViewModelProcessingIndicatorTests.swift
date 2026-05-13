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
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        viewModel = ChatViewModel(engineClient: engineClient, sessionId: "test-session")
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
        // User sent message, waiting for first thinking/text/capability invocation event
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
        // Sync messageIndex so isThinkingActivelyStreaming can find the message
        viewModel.messageIndex.rebuild(from: viewModel.messages)
        XCTAssertFalse(viewModel.shouldShowBreathingLine)
    }

    func testBreathingLineHiddenDuringToolExecution() {
        viewModel.agentPhase = .processing
        let tool = makeToolMessage(status: .running)
        viewModel.messages = [tool]
        viewModel.currentToolMessages = [tool.id: tool]
        // shouldShowBreathingLine checks runningToolCount (O(1) counter), not currentToolMessages
        viewModel.runningToolCount = 1
        XCTAssertFalse(viewModel.shouldShowBreathingLine)
    }

    func testBreathingLineHiddenDuringSubagentExecution() {
        viewModel.agentPhase = .processing
        viewModel.subagentState.trackSpawn(
            invocationId: "tc-1", subagentSessionId: "sub-1", task: "test", model: nil
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
        // shouldShowBreathingLine checks runningToolCount, not currentToolMessages
        viewModel.runningToolCount = 1
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

    // MARK: - shouldShowBreathingLine: spawn type filtering

    func testBreathingLineShownDuringHookSubagent() {
        // Hook subagents (title-gen, branch-name-gen) should NOT suppress the breathing line
        viewModel.agentPhase = .processing
        viewModel.subagentState.trackSpawn(
            invocationId: "sub-hook-1", subagentSessionId: "sub-hook-1",
            task: "Generate title", model: nil, spawnType: .hook
        )
        XCTAssertTrue(viewModel.shouldShowBreathingLine,
            "Hook subagents should not suppress the breathing line")
    }

    func testBreathingLineHiddenDuringToolSubagent() {
        // Tool-spawned subagents should still suppress the breathing line
        viewModel.agentPhase = .processing
        viewModel.subagentState.trackSpawn(
            invocationId: "tc-1", subagentSessionId: "sub-1",
            task: "Explore code", model: nil, spawnType: .toolAgent
        )
        XCTAssertFalse(viewModel.shouldShowBreathingLine,
            "Tool agent subagents should suppress the breathing line")
    }

    func testBreathingLineShownAfterHookSubagentCompletes() {
        viewModel.agentPhase = .processing
        viewModel.subagentState.trackSpawn(
            invocationId: "sub-hook-1", subagentSessionId: "sub-hook-1",
            task: "Generate title", model: nil, spawnType: .hook
        )
        viewModel.subagentState.complete(
            subagentSessionId: "sub-hook-1", resultSummary: "My Title",
            fullOutput: nil, totalTurns: 1, duration: 500, tokenUsage: nil, model: nil
        )
        XCTAssertTrue(viewModel.shouldShowBreathingLine)
    }

    func testBreathingLineHiddenDuringToolSubagent_withConcurrentHook() {
        // Both a tool agent and a hook running — tool agent takes precedence
        viewModel.agentPhase = .processing
        viewModel.subagentState.trackSpawn(
            invocationId: "sub-hook-1", subagentSessionId: "sub-hook-1",
            task: "Generate title", model: nil, spawnType: .hook
        )
        viewModel.subagentState.trackSpawn(
            invocationId: "tc-1", subagentSessionId: "sub-tool-1",
            task: "Explore code", model: nil, spawnType: .toolAgent
        )
        XCTAssertFalse(viewModel.shouldShowBreathingLine,
            "Tool agent should suppress breathing line even with concurrent hook")
    }

    // MARK: - Helpers

    private func makeToolMessage(status: CapabilityInvocationStatus) -> ChatMessage {
        ChatMessage(
            role: .assistant,
            content: .capabilityInvocation(testCapabilityInvocation(
                id: UUID().uuidString,
                status: status,
                result: status == .running ? nil : "ok"
            ))
        )
    }
}
