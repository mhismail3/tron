import XCTest
@testable import TronMobile

/// Tests for EventDispatchCoordinator - routes plugin events to appropriate handlers
/// Uses TDD: Tests written first, then implementation follows
@MainActor
final class EventDispatchCoordinatorTests: XCTestCase {

    var coordinator: EventDispatchCoordinator!
    var mockContext: MockEventDispatchContext!

    override func setUp() async throws {
        coordinator = EventDispatchCoordinator()
        mockContext = MockEventDispatchContext()
        // Ensure all plugins are registered for dispatch lookup
        EventRegistry.shared.clearForTesting()
        EventRegistry.shared.registerAll()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - Text/Thinking Event Tests

    func testDispatch_textDelta_callsHandleTextDelta() {
        // Given: A text delta result
        let result = TextDeltaPlugin.Result(delta: "Hello world", messageIndex: nil)

        // When: Dispatching
        coordinator.dispatch(
            type: TextDeltaPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called with correct delta
        XCTAssertEqual(mockContext.handleTextDeltaCalledWith, "Hello world")
    }

    func testDispatch_thinkingDelta_callsHandleThinkingDelta() {
        // Given: A thinking delta result
        let result = ThinkingDeltaPlugin.Result(delta: "Let me think...")

        // When: Dispatching
        coordinator.dispatch(
            type: ThinkingDeltaPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called with correct delta
        XCTAssertEqual(mockContext.handleThinkingDeltaCalledWith, "Let me think...")
    }

    // MARK: - Tool Event Tests

    func testDispatch_toolStart_callsHandleToolStart() {
        // Given: A tool start result
        let result = ToolStartPlugin.Result(
            toolName: "Read",
            toolCallId: "tool_123",
            arguments: nil
        )

        // When: Dispatching
        coordinator.dispatch(
            type: ToolStartPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleToolStartCalledWith?.toolCallId, "tool_123")
        XCTAssertEqual(mockContext.handleToolStartCalledWith?.toolName, "Read")
    }

    func testDispatch_toolEnd_callsHandleToolEnd() {
        // Given: A tool end result
        let result = ToolEndPlugin.Result(
            toolCallId: "tool_123",
            toolName: "Read",
            success: true,
            result: "file contents",
            error: nil,
            durationMs: 150,
            details: nil
        )

        // When: Dispatching
        coordinator.dispatch(
            type: ToolEndPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleToolEndCalledWith?.toolCallId, "tool_123")
        XCTAssertEqual(mockContext.handleToolEndCalledWith?.durationMs, 150)
    }

    // MARK: - Turn Lifecycle Event Tests

    func testDispatch_turnStart_callsHandleTurnStart() {
        // Given: A turn start result
        let result = TurnStartPlugin.Result(turnNumber: 1)

        // When: Dispatching
        coordinator.dispatch(
            type: TurnStartPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleTurnStartCalledWith?.turnNumber, 1)
    }

    func testDispatch_turnEnd_callsHandleTurnEnd() {
        // Given: A turn end result
        let result = TurnEndPlugin.Result(
            turnNumber: 1,
            duration: nil,
            tokenRecord: nil,
            stopReason: nil,
            cost: nil,
            contextLimit: nil
        )

        // When: Dispatching
        coordinator.dispatch(
            type: TurnEndPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleTurnEndCalledWith?.turnNumber, 1)
    }

    func testDispatch_agentTurn_callsHandleAgentTurn() {
        // Given: An agent turn result
        let result = AgentTurnPlugin.Result(messages: [], turnNumber: 2)

        // When: Dispatching
        coordinator.dispatch(
            type: AgentTurnPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleAgentTurnCalledWith?.turnNumber, 2)
    }

    func testDispatch_complete_callsHandleComplete() {
        // Given: A complete result
        let result = CompletePlugin.Result(success: true, totalTokens: nil, totalTurns: nil)

        // When: Dispatching
        coordinator.dispatch(
            type: CompletePlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertTrue(mockContext.handleCompleteCalled)
    }

    func testDispatch_agentReady_callsHandleAgentReady() {
        // Given: An agent ready result
        let result = AgentReadyPlugin.Result()

        // When: Dispatching
        coordinator.dispatch(
            type: AgentReadyPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertTrue(mockContext.handleAgentReadyCalled)
    }

    func testDispatch_error_callsHandleAgentError() {
        // Given: An error result
        let result = ErrorPlugin.Result(code: "ERROR", message: "Something went wrong")

        // When: Dispatching
        coordinator.dispatch(
            type: ErrorPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called with error message
        XCTAssertEqual(mockContext.handleAgentErrorCalledWith, "Something went wrong")
    }

    // MARK: - Context Operation Event Tests

    func testDispatch_compaction_callsHandleCompaction() {
        // Given: A compaction result
        let result = CompactionPlugin.Result(
            tokensBefore: 50000,
            tokensAfter: 30000,
            compressionRatio: 0.6,
            reason: "Context limit approaching",
            summary: "Summarized conversation history"
        )

        // When: Dispatching
        coordinator.dispatch(
            type: CompactionPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleCompactionCalledWith?.tokensBefore, 50000)
        XCTAssertEqual(mockContext.handleCompactionCalledWith?.tokensAfter, 30000)
    }

    func testDispatch_contextCleared_callsHandleContextCleared() {
        // Given: A context cleared result
        let result = ContextClearedPlugin.Result(tokensBefore: 50000, tokensAfter: 1000)

        // When: Dispatching
        coordinator.dispatch(
            type: ContextClearedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleContextClearedCalledWith?.tokensBefore, 50000)
    }

    func testDispatch_messageDeleted_callsHandleMessageDeleted() {
        // Given: A message deleted result
        let result = MessageDeletedPlugin.Result(
            targetEventId: "event_123",
            targetType: "user",
            targetTurn: nil,
            reason: nil
        )

        // When: Dispatching
        coordinator.dispatch(
            type: MessageDeletedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleMessageDeletedCalledWith?.targetEventId, "event_123")
    }

    func testDispatch_skillRemoved_callsHandleSkillRemoved() {
        // Given: A skill removed result
        let result = SkillRemovedPlugin.Result(skillName: "commit")

        // When: Dispatching
        coordinator.dispatch(
            type: SkillRemovedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleSkillRemovedCalledWith?.skillName, "commit")
    }

    // MARK: - Browser Event Tests

    func testDispatch_browserFrame_callsHandleBrowserFrame() {
        // Given: A browser frame result
        let result = BrowserFramePlugin.Result(frameData: "base64imagedata", format: nil, width: nil, height: nil)

        // When: Dispatching
        coordinator.dispatch(
            type: BrowserFramePlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleBrowserFrameCalledWith?.frameData, "base64imagedata")
    }

    func testDispatch_browserClosed_callsHandleBrowserClosed() {
        // Given: A browser closed result
        let result = BrowserClosedPlugin.Result(closedSessionId: "browser_session_123")

        // When: Dispatching
        coordinator.dispatch(
            type: BrowserClosedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleBrowserClosedCalledWith, "browser_session_123")
    }

    // MARK: - Subagent Event Tests

    func testDispatch_subagentSpawned_callsHandleSubagentSpawned() {
        // Given: A subagent spawned result
        let result = SubagentSpawnedPlugin.Result(
            subagentSessionId: "agent_123",
            task: "Search for files",
            model: nil,
            workingDirectory: nil,
            toolCallId: nil
        )

        // When: Dispatching
        coordinator.dispatch(
            type: SubagentSpawnedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleSubagentSpawnedCalledWith?.subagentSessionId, "agent_123")
    }

    func testDispatch_subagentStatus_callsHandleSubagentStatus() {
        // Given: A subagent status result
        let result = SubagentStatusPlugin.Result(
            subagentSessionId: "agent_123",
            status: "running",
            currentTurn: 1
        )

        // When: Dispatching
        coordinator.dispatch(
            type: SubagentStatusPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleSubagentStatusCalledWith?.subagentSessionId, "agent_123")
    }

    func testDispatch_subagentCompleted_callsHandleSubagentCompleted() {
        // Given: A subagent completed result
        let result = SubagentCompletedPlugin.Result(
            subagentSessionId: "agent_123",
            resultSummary: "Task completed successfully",
            fullOutput: nil,
            totalTurns: 3,
            duration: 5000,
            tokenUsage: nil,
            model: nil
        )

        // When: Dispatching
        coordinator.dispatch(
            type: SubagentCompletedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleSubagentCompletedCalledWith?.subagentSessionId, "agent_123")
    }

    func testDispatch_subagentFailed_callsHandleSubagentFailed() {
        // Given: A subagent failed result
        let result = SubagentFailedPlugin.Result(
            subagentSessionId: "agent_123",
            error: "Out of memory",
            duration: 1000
        )

        // When: Dispatching
        coordinator.dispatch(
            type: SubagentFailedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleSubagentFailedCalledWith?.subagentSessionId, "agent_123")
    }

    func testDispatch_subagentEvent_callsHandleSubagentEvent() {
        // Given: A subagent event result
        let result = SubagentEventPlugin.Result(
            subagentSessionId: "agent_123",
            innerEventType: "text_delta",
            innerEventData: AnyCodable(["delta": "Some text"]),
            innerEventTimestamp: "2024-01-01T00:00:00Z"
        )

        // When: Dispatching
        coordinator.dispatch(
            type: SubagentEventPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleSubagentEventCalledWith?.subagentSessionId, "agent_123")
    }

    // MARK: - UI Canvas Event Tests

    func testDispatch_uiRenderStart_callsHandleUIRenderStart() {
        // Given: A UI render start result
        let result = UIRenderStartPlugin.Result(canvasId: "canvas_123", title: nil, toolCallId: "tool_1")

        // When: Dispatching
        coordinator.dispatch(
            type: UIRenderStartPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleUIRenderStartCalledWith?.canvasId, "canvas_123")
    }

    func testDispatch_uiRenderChunk_callsHandleUIRenderChunk() {
        // Given: A UI render chunk result
        let result = UIRenderChunkPlugin.Result(canvasId: "canvas_123", chunk: "<div>", accumulated: "<div>Hello</div>")

        // When: Dispatching
        coordinator.dispatch(
            type: UIRenderChunkPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleUIRenderChunkCalledWith?.canvasId, "canvas_123")
    }

    func testDispatch_uiRenderComplete_callsHandleUIRenderComplete() {
        // Given: A UI render complete result
        let result = UIRenderCompletePlugin.Result(canvasId: "canvas_123", ui: nil, state: nil)

        // When: Dispatching
        coordinator.dispatch(
            type: UIRenderCompletePlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleUIRenderCompleteCalledWith?.canvasId, "canvas_123")
    }

    func testDispatch_uiRenderError_callsHandleUIRenderError() {
        // Given: A UI render error result
        let result = UIRenderErrorPlugin.Result(canvasId: "canvas_123", error: "Render failed")

        // When: Dispatching
        coordinator.dispatch(
            type: UIRenderErrorPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleUIRenderErrorCalledWith?.canvasId, "canvas_123")
    }

    func testDispatch_uiRenderRetry_callsHandleUIRenderRetry() {
        // Given: A UI render retry result
        let result = UIRenderRetryPlugin.Result(canvasId: "canvas_123", attempt: 2, errors: "Validation failed")

        // When: Dispatching
        coordinator.dispatch(
            type: UIRenderRetryPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleUIRenderRetryCalledWith?.canvasId, "canvas_123")
    }

    // MARK: - Todo Event Tests

    func testDispatch_todosUpdated_callsHandleTodosUpdated() {
        // Given: A todos updated result
        let result = TodosUpdatedPlugin.Result(todos: [], restoredCount: 0)

        // When: Dispatching
        coordinator.dispatch(
            type: TodosUpdatedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertTrue(mockContext.handleTodosUpdatedCalled)
    }

    // MARK: - Edge Case Tests

    func testDispatch_transformFailure_logsWarning() {
        // Given: A transform that returns nil
        let nilTransform: @Sendable () -> (any EventResult)? = { nil }

        // When: Dispatching
        coordinator.dispatch(
            type: TextDeltaPlugin.eventType,
            transform: nilTransform,
            context: mockContext
        )

        // Then: Warning should be logged
        XCTAssertTrue(mockContext.logWarningCalled)
    }

    func testDispatch_unknownType_logsDebug() {
        // Given: An unknown event type
        let result = TextDeltaPlugin.Result(delta: "test", messageIndex: nil)

        // When: Dispatching unknown type
        coordinator.dispatch(
            type: "unknown.event.type",
            transform: { result },
            context: mockContext
        )

        // Then: Debug message should be logged (unhandled event)
        XCTAssertTrue(mockContext.logDebugCalled)
    }

    func testDispatch_connectedEvent_ignored() {
        // Given: A connected event result
        let result = ConnectedPlugin.Result(serverId: nil, version: nil, clientId: nil)

        // When: Dispatching
        coordinator.dispatch(
            type: ConnectedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: No handler should be called (ConnectedPlugin is not dispatchable)
        XCTAssertFalse(mockContext.handleCompleteCalled)
        XCTAssertNil(mockContext.handleTextDeltaCalledWith)
        // ConnectedPlugin's box returns false from dispatch → logged as unhandled
        XCTAssertTrue(mockContext.logDebugCalled)
    }
}

// MARK: - Mock Context

/// Mock implementation of EventDispatchTarget for testing
@MainActor
final class MockEventDispatchContext: EventDispatchTarget {
    // MARK: - Text/Thinking
    var handleTextDeltaCalledWith: String?
    var handleThinkingDeltaCalledWith: String?

    // MARK: - Tools
    var handleToolStartCalledWith: ToolStartPlugin.Result?
    var handleToolEndCalledWith: ToolEndPlugin.Result?

    // MARK: - Turn Lifecycle
    var handleTurnStartCalledWith: TurnStartPlugin.Result?
    var handleTurnEndCalledWith: TurnEndPlugin.Result?
    var handleAgentTurnCalledWith: AgentTurnPlugin.Result?
    var handleCompleteCalled = false
    var handleAgentErrorCalledWith: String?

    // MARK: - Context Operations
    var handleCompactionCalledWith: CompactionPlugin.Result?
    var handleMemoryUpdatedCalledWith: MemoryUpdatedPlugin.Result?
    var handleContextClearedCalledWith: ContextClearedPlugin.Result?
    var handleMessageDeletedCalledWith: MessageDeletedPlugin.Result?
    var handleSkillRemovedCalledWith: SkillRemovedPlugin.Result?

    // MARK: - Browser
    var handleBrowserFrameCalledWith: BrowserFramePlugin.Result?
    var handleBrowserClosedCalledWith: String?

    // MARK: - Subagents
    var handleSubagentSpawnedCalledWith: SubagentSpawnedPlugin.Result?
    var handleSubagentStatusCalledWith: SubagentStatusPlugin.Result?
    var handleSubagentCompletedCalledWith: SubagentCompletedPlugin.Result?
    var handleSubagentFailedCalledWith: SubagentFailedPlugin.Result?
    var handleSubagentEventCalledWith: SubagentEventPlugin.Result?

    // MARK: - UI Canvas
    var handleUIRenderStartCalledWith: UIRenderStartPlugin.Result?
    var handleUIRenderChunkCalledWith: UIRenderChunkPlugin.Result?
    var handleUIRenderCompleteCalledWith: UIRenderCompletePlugin.Result?
    var handleUIRenderErrorCalledWith: UIRenderErrorPlugin.Result?
    var handleUIRenderRetryCalledWith: UIRenderRetryPlugin.Result?

    // MARK: - Todo
    var handleTodosUpdatedCalled = false

    // MARK: - Logging
    var logWarningCalled = false
    var logDebugCalled = false
    var logDebugCalledWith: String?

    // MARK: - Protocol Implementation

    func handleTextDelta(_ delta: String) {
        handleTextDeltaCalledWith = delta
    }

    func handleThinkingDelta(_ delta: String) {
        handleThinkingDeltaCalledWith = delta
    }

    func handleToolStart(_ result: ToolStartPlugin.Result) {
        handleToolStartCalledWith = result
    }

    func handleToolEnd(_ result: ToolEndPlugin.Result) {
        handleToolEndCalledWith = result
    }

    func handleTurnStart(_ result: TurnStartPlugin.Result) {
        handleTurnStartCalledWith = result
    }

    func handleTurnEnd(_ result: TurnEndPlugin.Result) {
        handleTurnEndCalledWith = result
    }

    func handleAgentTurn(_ result: AgentTurnPlugin.Result) {
        handleAgentTurnCalledWith = result
    }

    func handleComplete() {
        handleCompleteCalled = true
    }

    var handleAgentReadyCalled = false
    func handleAgentReady() {
        handleAgentReadyCalled = true
    }

    func handleAgentError(_ message: String) {
        handleAgentErrorCalledWith = message
    }

    func handleCompaction(_ result: CompactionPlugin.Result) {
        handleCompactionCalledWith = result
    }

    func handleMemoryUpdated(_ result: MemoryUpdatedPlugin.Result) {
        handleMemoryUpdatedCalledWith = result
    }

    func handleContextCleared(_ result: ContextClearedPlugin.Result) {
        handleContextClearedCalledWith = result
    }

    func handleMessageDeleted(_ result: MessageDeletedPlugin.Result) {
        handleMessageDeletedCalledWith = result
    }

    func handleSkillRemoved(_ result: SkillRemovedPlugin.Result) {
        handleSkillRemovedCalledWith = result
    }

    func handleBrowserFrame(_ result: BrowserFramePlugin.Result) {
        handleBrowserFrameCalledWith = result
    }

    func handleBrowserClosed(_ sessionId: String) {
        handleBrowserClosedCalledWith = sessionId
    }

    func handleSubagentSpawned(_ result: SubagentSpawnedPlugin.Result) {
        handleSubagentSpawnedCalledWith = result
    }

    func handleSubagentStatus(_ result: SubagentStatusPlugin.Result) {
        handleSubagentStatusCalledWith = result
    }

    func handleSubagentCompleted(_ result: SubagentCompletedPlugin.Result) {
        handleSubagentCompletedCalledWith = result
    }

    func handleSubagentFailed(_ result: SubagentFailedPlugin.Result) {
        handleSubagentFailedCalledWith = result
    }

    func handleSubagentEvent(_ result: SubagentEventPlugin.Result) {
        handleSubagentEventCalledWith = result
    }

    func handleSubagentResultAvailable(_ result: SubagentResultAvailablePlugin.Result) {
        // No-op for test mock
    }

    func handleUIRenderStart(_ result: UIRenderStartPlugin.Result) {
        handleUIRenderStartCalledWith = result
    }

    func handleUIRenderChunk(_ result: UIRenderChunkPlugin.Result) {
        handleUIRenderChunkCalledWith = result
    }

    func handleUIRenderComplete(_ result: UIRenderCompletePlugin.Result) {
        handleUIRenderCompleteCalledWith = result
    }

    func handleUIRenderError(_ result: UIRenderErrorPlugin.Result) {
        handleUIRenderErrorCalledWith = result
    }

    func handleUIRenderRetry(_ result: UIRenderRetryPlugin.Result) {
        handleUIRenderRetryCalledWith = result
    }

    func handleTodosUpdated(_ result: TodosUpdatedPlugin.Result) {
        handleTodosUpdatedCalled = true
    }

    func logWarning(_ message: String) {
        logWarningCalled = true
    }

    func logDebug(_ message: String) {
        logDebugCalled = true
        logDebugCalledWith = message
    }
}
