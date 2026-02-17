import XCTest
@testable import TronMobile

/// Tests for TurnLifecycleCoordinator
/// Following TDD - tests written FIRST before implementation
@MainActor
final class TurnLifecycleCoordinatorTests: XCTestCase {

    private var coordinator: TurnLifecycleCoordinator!
    private var mockContext: MockTurnLifecycleContext!

    override func setUp() async throws {
        coordinator = TurnLifecycleCoordinator()
        mockContext = MockTurnLifecycleContext()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - handleTurnStart Tests

    func testTurnStartResetsAskUserQuestionCalledInTurn() {
        // Given
        mockContext.askUserQuestionCalledInTurn = true

        // When
        let event = TurnStartPlugin.Result(turnNumber: 1)
        let result = TurnStartResult(turnNumber: 1, stateReset: false)
        coordinator.handleTurnStart(event, result: result, context: mockContext)

        // Then
        XCTAssertFalse(mockContext.askUserQuestionCalledInTurn)
    }

    func testTurnStartFinalizesStreamingIfNeeded() {
        // Given
        mockContext.hasActiveStreaming = true
        mockContext.streamingText = "Some text"

        // When
        let event = TurnStartPlugin.Result(turnNumber: 1)
        let result = TurnStartResult(turnNumber: 1, stateReset: false)
        coordinator.handleTurnStart(event, result: result, context: mockContext)

        // Then
        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testTurnStartClearsThinkingMessageId() {
        // Given
        mockContext.thinkingMessageId = UUID()

        // When
        let event = TurnStartPlugin.Result(turnNumber: 1)
        let result = TurnStartResult(turnNumber: 1, stateReset: false)
        coordinator.handleTurnStart(event, result: result, context: mockContext)

        // Then
        XCTAssertNil(mockContext.thinkingMessageId)
    }

    func testTurnStartNotifiesThinkingState() {
        // Given
        mockContext.currentModel = "claude-3-opus"

        // When
        let event = TurnStartPlugin.Result(turnNumber: 3)
        let result = TurnStartResult(turnNumber: 3, stateReset: false)
        coordinator.handleTurnStart(event, result: result, context: mockContext)

        // Then
        XCTAssertEqual(mockContext.thinkingStateStartTurnCalled, 3)
        XCTAssertEqual(mockContext.thinkingStateModelUsed, "claude-3-opus")
    }

    func testTurnStartClearsPreviousTurnToolTracking() {
        // Given
        mockContext.currentTurnToolCalls = [
            ToolCallRecord(toolCallId: "tool1", toolName: "Bash", arguments: "{}")
        ]
        mockContext.currentToolMessages = [UUID(): makeTextMessage("test")]

        // When
        let event = TurnStartPlugin.Result(turnNumber: 2)
        let result = TurnStartResult(turnNumber: 2, stateReset: false)
        coordinator.handleTurnStart(event, result: result, context: mockContext)

        // Then
        XCTAssertTrue(mockContext.currentTurnToolCalls.isEmpty)
        XCTAssertTrue(mockContext.currentToolMessages.isEmpty)
    }

    func testTurnStartEnqueuesTurnBoundary() {
        // When
        let event = TurnStartPlugin.Result(turnNumber: 5)
        let result = TurnStartResult(turnNumber: 5, stateReset: false)
        coordinator.handleTurnStart(event, result: result, context: mockContext)

        // Then
        XCTAssertEqual(mockContext.enqueuedTurnBoundary?.turnNumber, 5)
        XCTAssertTrue(mockContext.enqueuedTurnBoundary?.isStart ?? false)
    }

    func testTurnStartResetsAnimationCoordinatorToolState() {
        // When
        let event = TurnStartPlugin.Result(turnNumber: 1)
        let result = TurnStartResult(turnNumber: 1, stateReset: false)
        coordinator.handleTurnStart(event, result: result, context: mockContext)

        // Then
        XCTAssertTrue(mockContext.animationCoordinatorResetToolStateCalled)
    }

    func testTurnStartTracksTurnBoundaryIndex() {
        // Given
        mockContext.messages = [
            makeTextMessage("msg1"),
            makeTextMessage("msg2")
        ]

        // When
        let event = TurnStartPlugin.Result(turnNumber: 1)
        let result = TurnStartResult(turnNumber: 1, stateReset: false)
        coordinator.handleTurnStart(event, result: result, context: mockContext)

        // Then
        XCTAssertEqual(mockContext.turnStartMessageIndex, 2) // Count of existing messages
        XCTAssertNil(mockContext.firstTextMessageIdForTurn)
    }

    // MARK: - handleTurnEnd Tests

    func testTurnEndMarksThinkingAsNoLongerStreaming() {
        // Given
        let thinkingId = UUID()
        mockContext.thinkingMessageId = thinkingId
        mockContext.messages = [
            ChatMessage(id: thinkingId, role: .assistant, content: .thinking(visible: "thinking...", isExpanded: false, isStreaming: true))
        ]

        // When
        let event = makeTurnEndResult(turnNumber: 1)
        let result = TurnEndResult(
            turnNumber: 1,
            stopReason: "end_turn",
            tokenRecord: makeTokenRecord(inputTokens: 100, outputTokens: 50),
            contextLimit: nil,
            cost: nil,
            durationMs: 1000
        )
        coordinator.handleTurnEnd(event, result: result, context: mockContext)

        // Then
        if case .thinking(_, _, let isStreaming) = mockContext.messages[0].content {
            XCTAssertFalse(isStreaming)
        } else {
            XCTFail("Expected thinking content")
        }
    }

    func testTurnEndUpdatesMessageMetadata() {
        // Given
        let messageId = UUID()
        mockContext.streamingMessageId = messageId
        mockContext.currentModel = "claude-3-opus"
        mockContext.messages = [
            ChatMessage(id: messageId, role: .assistant, content: .text("response"))
        ]

        // When
        let event = makeTurnEndResult(turnNumber: 2)
        let result = TurnEndResult(
            turnNumber: 2,
            stopReason: "end_turn",
            tokenRecord: makeTokenRecord(inputTokens: 100, outputTokens: 50, turn: 2),
            contextLimit: nil,
            cost: nil,
            durationMs: 1500
        )
        coordinator.handleTurnEnd(event, result: result, context: mockContext)

        // Then
        let msg = mockContext.messages[0]
        XCTAssertEqual(msg.tokenRecord?.source.rawInputTokens, 100)
        XCTAssertEqual(msg.tokenRecord?.source.rawOutputTokens, 50)
        XCTAssertEqual(msg.model, "claude-3-opus")
        XCTAssertEqual(msg.latencyMs, 1500)
        XCTAssertEqual(msg.stopReason, "end_turn")
        XCTAssertEqual(msg.turnNumber, 2)
    }

    func testTurnEndUsesFirstTextMessageIdWhenStreamingFinalizedEarly() {
        // Given - streaming was finalized before turn end (e.g., before tool call)
        let firstTextId = UUID()
        mockContext.streamingMessageId = nil
        mockContext.firstTextMessageIdForTurn = firstTextId
        mockContext.currentModel = "claude-3-opus"
        mockContext.messages = [
            ChatMessage(id: firstTextId, role: .assistant, content: .text("response"))
        ]

        // When
        let event = makeTurnEndResult(turnNumber: 1)
        let result = TurnEndResult(
            turnNumber: 1,
            stopReason: "end_turn",
            tokenRecord: makeTokenRecord(inputTokens: 100, outputTokens: 50),
            contextLimit: nil,
            cost: nil,
            durationMs: 1000
        )
        coordinator.handleTurnEnd(event, result: result, context: mockContext)

        // Then - should find message via firstTextMessageIdForTurn
        XCTAssertEqual(mockContext.messages[0].turnNumber, 1)
    }

    func testTurnEndAssignsTokenRecordToMessage() {
        // Given
        let messageId = UUID()
        mockContext.streamingMessageId = messageId
        mockContext.messages = [
            ChatMessage(id: messageId, role: .assistant, content: .text("response"))
        ]

        // When
        let event = makeTurnEndResult(turnNumber: 1)
        let tokenRecord = makeTokenRecord(
            inputTokens: 1500,
            outputTokens: 200,
            contextWindow: 1000,
            newInput: 500
        )
        let result = TurnEndResult(
            turnNumber: 1,
            stopReason: "end_turn",
            tokenRecord: tokenRecord,
            contextLimit: nil,
            cost: nil,
            durationMs: 1000
        )
        coordinator.handleTurnEnd(event, result: result, context: mockContext)

        // Then
        let record = mockContext.messages[0].tokenRecord
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.computed.newInputTokens, 500)
        XCTAssertEqual(record?.source.rawOutputTokens, 200)
        XCTAssertEqual(record?.computed.contextWindowTokens, 1000)
    }

    func testTurnEndRemovesCatchingUpMessage() {
        // Given
        let catchUpId = UUID()
        mockContext.catchingUpMessageId = catchUpId
        mockContext.messages = [
            makeTextMessage("response"),
            ChatMessage(id: catchUpId, role: .system, content: .text("Catching up..."))
        ]

        // When
        let event = makeTurnEndResult(turnNumber: 1)
        let result = TurnEndResult(
            turnNumber: 1,
            stopReason: "end_turn",
            tokenRecord: nil,
            contextLimit: nil,
            cost: nil,
            durationMs: 1000
        )
        coordinator.handleTurnEnd(event, result: result, context: mockContext)

        // Then
        XCTAssertEqual(mockContext.messages.count, 1)
        XCTAssertNil(mockContext.catchingUpMessageId)
    }

    func testTurnEndUpdatesContextStateFromTokenRecord() {
        // Given
        let tokenRecord = makeTokenRecord(
            inputTokens: 1500,
            outputTokens: 200,
            contextWindow: 1000,
            newInput: 500
        )

        // When
        let event = makeTurnEndResult(turnNumber: 1)
        let result = TurnEndResult(
            turnNumber: 1,
            stopReason: "end_turn",
            tokenRecord: tokenRecord,
            contextLimit: nil,
            cost: nil,
            durationMs: 1000
        )
        coordinator.handleTurnEnd(event, result: result, context: mockContext)

        // Then
        XCTAssertTrue(mockContext.contextStateUpdateFromTokenRecordCalled)
    }

    func testTurnEndUpdatesContextLimit() {
        // When
        let event = makeTurnEndResult(turnNumber: 1)
        let result = TurnEndResult(
            turnNumber: 1,
            stopReason: "end_turn",
            tokenRecord: nil,
            contextLimit: 200000,
            cost: nil,
            durationMs: 1000
        )
        coordinator.handleTurnEnd(event, result: result, context: mockContext)

        // Then
        XCTAssertEqual(mockContext.contextStateCurrentContextWindow, 200000)
    }

    func testTurnEndFallsBackToToolUseMessageWhenNoTextExists() {
        // Given - intermediate turn: [thinking, tool_use] with NO visible text
        // streamingMessageId and firstTextMessageIdForTurn are both nil
        mockContext.streamingMessageId = nil
        mockContext.firstTextMessageIdForTurn = nil
        mockContext.turnStartMessageIndex = 0
        mockContext.currentModel = "claude-opus-4-6"

        let toolUseMessage = ChatMessage(
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: "Bash",
                toolCallId: "tc-1",
                arguments: "{}",
                status: .running
            ))
        )
        mockContext.messages = [toolUseMessage]

        // When
        let event = makeTurnEndResult(turnNumber: 1)
        let tokenRecord = makeTokenRecord(inputTokens: 100, outputTokens: 50)
        let result = TurnEndResult(
            turnNumber: 1,
            stopReason: "tool_use",
            tokenRecord: tokenRecord,
            contextLimit: nil,
            cost: nil,
            durationMs: 500
        )
        coordinator.handleTurnEnd(event, result: result, context: mockContext)

        // Then - should find the toolUse message via last-message search
        XCTAssertNotNil(mockContext.messages[0].tokenRecord)
        XCTAssertEqual(mockContext.messages[0].tokenRecord?.source.rawInputTokens, 100)
        XCTAssertEqual(mockContext.messages[0].turnNumber, 1)
    }

    func testTurnEndAssignsMetadataToLastMessageInTurn() {
        // Given - turn has [toolUse, text] — last message is text
        mockContext.streamingMessageId = nil
        mockContext.firstTextMessageIdForTurn = nil
        mockContext.turnStartMessageIndex = 0
        mockContext.currentModel = "claude-opus-4-6"

        let toolUseMessage = ChatMessage(
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: "Bash",
                toolCallId: "tc-1",
                arguments: "{}",
                status: .success
            ))
        )
        let textMessage = ChatMessage(role: .assistant, content: .text("some response"))
        mockContext.messages = [toolUseMessage, textMessage]

        // When
        let event = makeTurnEndResult(turnNumber: 1)
        let tokenRecord = makeTokenRecord(inputTokens: 200, outputTokens: 100)
        let result = TurnEndResult(
            turnNumber: 1,
            stopReason: "end_turn",
            tokenRecord: tokenRecord,
            contextLimit: nil,
            cost: nil,
            durationMs: 800
        )
        coordinator.handleTurnEnd(event, result: result, context: mockContext)

        // Then - stats go on the last message (text at index 1)
        XCTAssertNil(mockContext.messages[0].tokenRecord)
        XCTAssertNotNil(mockContext.messages[1].tokenRecord)
    }

    func testTurnEndAssignsMetadataToLastToolInParallelTools() {
        // Given - turn with [text, tool1, tool2, tool3] — parallel tool calls
        // This is the bug case: stats must go on the LAST tool, not the text or first tool
        mockContext.streamingMessageId = nil
        mockContext.firstTextMessageIdForTurn = nil
        mockContext.turnStartMessageIndex = 0
        mockContext.currentModel = "claude-opus-4-6"

        let textMessage = ChatMessage(role: .assistant, content: .text("Let me search for that."))
        let tool1 = ChatMessage(role: .assistant, content: .toolUse(ToolUseData(
            toolName: "Search", toolCallId: "tc-1", arguments: "{}", status: .success
        )))
        let tool2 = ChatMessage(role: .assistant, content: .toolUse(ToolUseData(
            toolName: "Search", toolCallId: "tc-2", arguments: "{}", status: .success
        )))
        let tool3 = ChatMessage(role: .assistant, content: .toolUse(ToolUseData(
            toolName: "Search", toolCallId: "tc-3", arguments: "{}", status: .success
        )))
        mockContext.messages = [textMessage, tool1, tool2, tool3]

        // When
        let event = makeTurnEndResult(turnNumber: 1)
        let tokenRecord = makeTokenRecord(inputTokens: 500, outputTokens: 200)
        let result = TurnEndResult(
            turnNumber: 1,
            stopReason: "tool_use",
            tokenRecord: tokenRecord,
            contextLimit: nil,
            cost: nil,
            durationMs: 1200
        )
        coordinator.handleTurnEnd(event, result: result, context: mockContext)

        // Then - stats must go on the LAST tool (index 3), not text or first tool
        XCTAssertNil(mockContext.messages[0].tokenRecord)  // text — no stats
        XCTAssertNil(mockContext.messages[1].tokenRecord)  // tool1 — no stats
        XCTAssertNil(mockContext.messages[2].tokenRecord)  // tool2 — no stats
        XCTAssertNotNil(mockContext.messages[3].tokenRecord)  // tool3 — stats here
        XCTAssertEqual(mockContext.messages[3].model, "claude-opus-4-6")
        XCTAssertEqual(mockContext.messages[3].latencyMs, 1200)
    }

    func testTurnEndAssignsMetadataToLastToolInToolOnlyTurn() {
        // Given - tool-only turn: [tool1, tool2] — no text at all
        mockContext.streamingMessageId = nil
        mockContext.firstTextMessageIdForTurn = nil
        mockContext.turnStartMessageIndex = 0
        mockContext.currentModel = "claude-opus-4-6"

        let tool1 = ChatMessage(role: .assistant, content: .toolUse(ToolUseData(
            toolName: "Bash", toolCallId: "tc-1", arguments: "{}", status: .success
        )))
        let tool2 = ChatMessage(role: .assistant, content: .toolUse(ToolUseData(
            toolName: "Read", toolCallId: "tc-2", arguments: "{}", status: .success
        )))
        mockContext.messages = [tool1, tool2]

        // When
        let event = makeTurnEndResult(turnNumber: 2)
        let tokenRecord = makeTokenRecord(inputTokens: 300, outputTokens: 100)
        let result = TurnEndResult(
            turnNumber: 2,
            stopReason: "tool_use",
            tokenRecord: tokenRecord,
            contextLimit: nil,
            cost: nil,
            durationMs: 600
        )
        coordinator.handleTurnEnd(event, result: result, context: mockContext)

        // Then - stats go on the last tool (index 1)
        XCTAssertNil(mockContext.messages[0].tokenRecord)
        XCTAssertNotNil(mockContext.messages[1].tokenRecord)
        XCTAssertEqual(mockContext.messages[1].tokenRecord?.source.rawInputTokens, 300)
    }

    func testTurnEndClearsTurnTracking() {
        // Given
        mockContext.turnStartMessageIndex = 5
        mockContext.firstTextMessageIdForTurn = UUID()

        // When
        let event = makeTurnEndResult(turnNumber: 1)
        let result = TurnEndResult(
            turnNumber: 1,
            stopReason: "end_turn",
            tokenRecord: nil,
            contextLimit: nil,
            cost: nil,
            durationMs: 1000
        )
        coordinator.handleTurnEnd(event, result: result, context: mockContext)

        // Then
        XCTAssertNil(mockContext.turnStartMessageIndex)
        XCTAssertNil(mockContext.firstTextMessageIdForTurn)
    }

    // MARK: - handleComplete Tests

    func testCompleteFlushesAndResetsManagers() {
        // When
        coordinator.handleComplete(streamingText: "", context: mockContext)

        // Then
        XCTAssertTrue(mockContext.uiUpdateQueueFlushCalled)
        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.uiUpdateQueueResetCalled)
        XCTAssertTrue(mockContext.animationCoordinatorResetToolStateCalled)
        XCTAssertTrue(mockContext.streamingManagerResetCalled)
    }

    func testCompleteDoesNotSetAgentPhaseDirectly() {
        // The coordinator should NOT modify agentPhase — the caller
        // (ChatViewModel+Events.handleComplete) sets .postProcessing after
        // the coordinator returns. Previously the coordinator set
        // isProcessing = false (→ .idle), causing a transient .idle flash.
        mockContext.agentPhase = .processing

        coordinator.handleComplete(streamingText: "", context: mockContext)

        // agentPhase must remain unchanged by the coordinator
        XCTAssertEqual(mockContext.agentPhase, .processing)
    }

    func testCompleteRemovesCatchingUpMessage() {
        // Given
        let catchUpId = UUID()
        mockContext.catchingUpMessageId = catchUpId
        mockContext.messages = [
            makeTextMessage("response"),
            ChatMessage(id: catchUpId, role: .system, content: .text("Catching up..."))
        ]

        // When
        coordinator.handleComplete(streamingText: "", context: mockContext)

        // Then
        XCTAssertEqual(mockContext.messages.count, 1)
        XCTAssertNil(mockContext.catchingUpMessageId)
    }

    func testCompleteResetsBrowserDismissal() {
        // Given
        mockContext.browserDismissal = .userDismissed

        // When
        coordinator.handleComplete(streamingText: "", context: mockContext)

        // Then
        XCTAssertEqual(mockContext.browserDismissal, .none)
    }

    func testCompleteClearsToolTracking() {
        // Given
        mockContext.currentToolMessages = [UUID(): makeTextMessage("test")]
        mockContext.currentTurnToolCalls = [
            ToolCallRecord(toolCallId: "tool1", toolName: "Bash", arguments: "{}")
        ]

        // When
        coordinator.handleComplete(streamingText: "", context: mockContext)

        // Then
        XCTAssertTrue(mockContext.currentToolMessages.isEmpty)
        XCTAssertTrue(mockContext.currentTurnToolCalls.isEmpty)
    }

    func testCompleteClosesBrowserSession() {
        // When
        coordinator.handleComplete(streamingText: "", context: mockContext)

        // Then
        XCTAssertTrue(mockContext.closeBrowserSessionCalled)
    }

    func testCompleteTriggersContextRefresh() async throws {
        // When
        coordinator.handleComplete(streamingText: "", context: mockContext)

        // Wait briefly for the async Task to execute
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Then
        XCTAssertTrue(mockContext.refreshContextFromServerCalled)
    }

    // MARK: - Helpers

    private func makeTurnEndResult(turnNumber: Int) -> TurnEndPlugin.Result {
        TurnEndPlugin.Result(
            turnNumber: turnNumber,
            duration: nil,
            tokenRecord: nil,
            stopReason: "end_turn",
            cost: nil,
            contextLimit: nil
        )
    }

    private func makeTextMessage(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .text(text))
    }

    private func makeTokenRecord(
        inputTokens: Int = 100,
        outputTokens: Int = 50,
        contextWindow: Int? = nil,
        newInput: Int? = nil,
        turn: Int = 1
    ) -> TokenRecord {
        TokenRecord(
            source: TokenSource(
                provider: "anthropic",
                timestamp: "2024-01-15T10:30:00.000Z",
                rawInputTokens: inputTokens,
                rawOutputTokens: outputTokens,
                rawCacheReadTokens: 0,
                rawCacheCreationTokens: 0
            ),
            computed: ComputedTokens(
                contextWindowTokens: contextWindow ?? inputTokens,
                newInputTokens: newInput ?? inputTokens,
                previousContextBaseline: 0,
                calculationMethod: "anthropic_cache_aware"
            ),
            meta: TokenMeta(
                turn: turn,
                sessionId: "test-session",
                extractedAt: "2024-01-15T10:30:00.000Z",
                normalizedAt: "2024-01-15T10:30:00.001Z"
            )
        )
    }
}

// MARK: - Mock Context

@MainActor
final class MockTurnLifecycleContext: TurnLifecycleContext {
    // MARK: - State
    var messages: [ChatMessage] = []
    var currentToolMessages: [UUID: ChatMessage] = [:]
    var currentTurnToolCalls: [ToolCallRecord] = []
    var askUserQuestionCalledInTurn: Bool = false
    var thinkingMessageId: UUID?
    var turnStartMessageIndex: Int?
    var firstTextMessageIdForTurn: UUID?
    var streamingMessageId: UUID?
    var streamingText: String = ""
    var hasActiveStreaming: Bool = false
    var currentModel: String = "claude-3-sonnet"
    var agentPhase: AgentPhase = .idle
    var catchingUpMessageId: UUID?
    var browserDismissal: BrowserDismissal = .none
    var sessionId: String = "test-session"
    var browserStatus: BrowserGetStatusResult?

    // Context state tracking
    var contextStateCurrentContextWindow: Int = 0
    var contextStateUpdateFromTokenRecordCalled = false

    // MARK: - Call tracking
    var flushPendingTextUpdatesCalled = false
    var finalizeStreamingMessageCalled = false
    var thinkingStateStartTurnCalled: Int?
    var thinkingStateModelUsed: String?
    var enqueuedTurnBoundary: UIUpdateQueue.TurnBoundaryData?
    var animationCoordinatorResetToolStateCalled = false
    var uiUpdateQueueFlushCalled = false
    var uiUpdateQueueResetCalled = false
    var streamingManagerResetCalled = false
    var closeBrowserSessionCalled = false
    var refreshContextFromServerCalled = false
    var thinkingStateEndTurnCalled = false

    // MARK: - Protocol Methods

    func flushPendingTextUpdates() {
        flushPendingTextUpdatesCalled = true
    }

    func finalizeStreamingMessage() {
        finalizeStreamingMessageCalled = true
    }

    func startThinkingTurn(_ turnNumber: Int, model: String) {
        thinkingStateStartTurnCalled = turnNumber
        thinkingStateModelUsed = model
    }

    func endThinkingTurn() async {
        thinkingStateEndTurnCalled = true
    }

    func enqueueTurnBoundary(_ data: UIUpdateQueue.TurnBoundaryData) {
        enqueuedTurnBoundary = data
    }

    func resetAnimationCoordinatorToolState() {
        animationCoordinatorResetToolStateCalled = true
    }

    func flushUIUpdateQueue() {
        uiUpdateQueueFlushCalled = true
    }

    func resetUIUpdateQueue() {
        uiUpdateQueueResetCalled = true
    }

    func resetStreamingManager() {
        streamingManagerResetCalled = true
    }

    func closeBrowserSession() {
        closeBrowserSessionCalled = true
    }

    func refreshContextFromServer() async {
        refreshContextFromServerCalled = true
    }

    func updateContextStateFromTokenRecord(_ record: TokenRecord) {
        contextStateUpdateFromTokenRecordCalled = true
    }

    func setContextStateCurrentContextWindow(_ limit: Int) {
        contextStateCurrentContextWindow = limit
    }

    func accumulateTokens(input: Int, output: Int, cacheRead: Int, cacheCreation: Int, cost: Double) {
        // No-op for mock
    }

    func updateTotalTokenUsage(contextSize: Int, outputTokens: Int, cacheRead: Int?, cacheCreation: Int?) {
        // No-op for mock
    }

    func updateSessionTokens(inputTokens: Int, outputTokens: Int, lastTurnInputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int, cost: Double) throws {
        // No-op for mock
    }

    func setSessionProcessing(_ isProcessing: Bool) {
        // No-op for mock
    }

    func updateSessionDashboardInfo(lastAssistantResponse: String?, lastToolCount: Int?) {
        // No-op for mock
    }

    // MARK: - Logging
    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
    func showError(_ message: String) {}
}

