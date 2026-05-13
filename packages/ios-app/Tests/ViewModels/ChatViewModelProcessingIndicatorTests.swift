import XCTest
@testable import TronMobile

/// Tests for ChatViewModel.shouldShowProcessingIndicator and shouldShowBreathingLine.
///
/// The breathing line ("Processing...") appears only when the model is actively
/// thinking and NO other visual feedback is present: no text streaming, no thinking
/// block streaming, no capability spinner, no subagent chip.
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

    func testBreathingLineShownAfterCapabilityCompletes() {
        // Capability finished, model deciding next action
        viewModel.agentPhase = .processing
        let capability = makeCapabilityMessage(status: .success)
        viewModel.messages = [capability]
        viewModel.currentCapabilityInvocationMessages = [capability.id: capability]
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

    func testBreathingLineHiddenDuringCapabilityExecution() {
        viewModel.agentPhase = .processing
        let capability = makeCapabilityMessage(status: .running)
        viewModel.messages = [capability]
        viewModel.currentCapabilityInvocationMessages = [capability.id: capability]
        // shouldShowBreathingLine checks runningCapabilityInvocationCount (O(1) counter), not currentCapabilityInvocationMessages
        viewModel.runningCapabilityInvocationCount = 1
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

    func testBreathingLineHiddenWhenOneCapabilityRunningOneComplete() {
        // Two capabilities: one done, one still running → capability spinner visible
        viewModel.agentPhase = .processing
        let done = makeCapabilityMessage(status: .success)
        let running = makeCapabilityMessage(status: .running)
        viewModel.messages = [done, running]
        viewModel.currentCapabilityInvocationMessages = [done.id: done, running.id: running]
        // shouldShowBreathingLine checks runningCapabilityInvocationCount, not currentCapabilityInvocationMessages
        viewModel.runningCapabilityInvocationCount = 1
        XCTAssertFalse(viewModel.shouldShowBreathingLine)
    }

    func testBreathingLineShownWhenAllCapabilitiesComplete() {
        // Two capabilities both done → no spinner, model is thinking
        viewModel.agentPhase = .processing
        let done1 = makeCapabilityMessage(status: .success)
        let done2 = makeCapabilityMessage(status: .success)
        viewModel.messages = [done1, done2]
        viewModel.currentCapabilityInvocationMessages = [done1.id: done1, done2.id: done2]
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

    func testBreathingLineHiddenDuringCapabilitySubagent() {
        // Capability-spawned subagents should still suppress the breathing line
        viewModel.agentPhase = .processing
        viewModel.subagentState.trackSpawn(
            invocationId: "tc-1", subagentSessionId: "sub-1",
            task: "Explore code", model: nil, spawnType: .capabilityAgent
        )
        XCTAssertFalse(viewModel.shouldShowBreathingLine,
            "Capability agent subagents should suppress the breathing line")
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

    func testBreathingLineHiddenDuringCapabilitySubagent_withConcurrentHook() {
        // Both a capability agent and a hook running — capability agent takes precedence
        viewModel.agentPhase = .processing
        viewModel.subagentState.trackSpawn(
            invocationId: "sub-hook-1", subagentSessionId: "sub-hook-1",
            task: "Generate title", model: nil, spawnType: .hook
        )
        viewModel.subagentState.trackSpawn(
            invocationId: "tc-1", subagentSessionId: "sub-capability-1",
            task: "Explore code", model: nil, spawnType: .capabilityAgent
        )
        XCTAssertFalse(viewModel.shouldShowBreathingLine,
            "Capability agent should suppress breathing line even with concurrent hook")
    }

    // MARK: - Helpers

    private func makeCapabilityMessage(status: CapabilityInvocationStatus) -> ChatMessage {
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
