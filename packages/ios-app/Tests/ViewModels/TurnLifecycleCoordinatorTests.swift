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

    func testTurnStartFinalizesStreamingIfNeeded() {
        // Given
        mockContext.hasActiveStreaming = true
        mockContext.streamingText = "Some text"

        // When
        let pluginResult = TurnStartPlugin.Result(turnNumber: 1, agentPhase: "processing")
        coordinator.handleTurnStart(pluginResult, context: mockContext)

        // Then
        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testTurnStartClearsThinkingMessageId() {
        // Given
        mockContext.thinkingMessageId = UUID()

        // When
        let pluginResult = TurnStartPlugin.Result(turnNumber: 1, agentPhase: "processing")
        coordinator.handleTurnStart(pluginResult, context: mockContext)

        // Then
        XCTAssertNil(mockContext.thinkingMessageId)
    }

    func testTurnStartNotifiesThinkingState() {
        // Given
        mockContext.currentModel = "claude-3-opus"

        // When
        let pluginResult = TurnStartPlugin.Result(turnNumber: 3, agentPhase: "processing")
        coordinator.handleTurnStart(pluginResult, context: mockContext)

        // Then
        XCTAssertEqual(mockContext.thinkingStateStartTurnCalled, 3)
        XCTAssertEqual(mockContext.thinkingStateModelUsed, "claude-3-opus")
    }

    func testTurnStartClearsPreviousTurnCapabilityTracking() {
        // Given
        mockContext.currentTurnCapabilityInvocations = [
            CapabilityInvocationRecord(invocationId: "invocation1", modelPrimitiveName: "execute", arguments: "{}")
        ]
        mockContext.currentCapabilityInvocationMessages = [UUID(): makeTextMessage("test")]

        // When
        let pluginResult = TurnStartPlugin.Result(turnNumber: 2, agentPhase: "processing")
        coordinator.handleTurnStart(pluginResult, context: mockContext)

        // Then
        XCTAssertTrue(mockContext.currentTurnCapabilityInvocations.isEmpty)
        XCTAssertTrue(mockContext.currentCapabilityInvocationMessages.isEmpty)
    }

    func testTurnStartEnqueuesTurnBoundary() {
        // When
        let pluginResult = TurnStartPlugin.Result(turnNumber: 5, agentPhase: "processing")
        coordinator.handleTurnStart(pluginResult, context: mockContext)

        // Then
        XCTAssertEqual(mockContext.enqueuedTurnBoundary?.turnNumber, 5)
        XCTAssertTrue(mockContext.enqueuedTurnBoundary?.isStart ?? false)
    }

    func testTurnStartResetsAnimationCoordinatorCapabilityState() {
        // When
        let pluginResult = TurnStartPlugin.Result(turnNumber: 1, agentPhase: "processing")
        coordinator.handleTurnStart(pluginResult, context: mockContext)

        // Then
        XCTAssertTrue(mockContext.animationCoordinatorResetCapabilityStateCalled)
    }

    func testTurnStartTracksTurnBoundaryIndex() {
        // Given
        mockContext.messages = [
            makeTextMessage("msg1"),
            makeTextMessage("msg2")
        ]

        // When
        let pluginResult = TurnStartPlugin.Result(turnNumber: 1, agentPhase: "processing")
        coordinator.handleTurnStart(pluginResult, context: mockContext)

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
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 1,
            tokenRecord: makeTokenRecord(inputTokens: 100, outputTokens: 50),
            duration: 1000
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

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
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 2,
            tokenRecord: makeTokenRecord(inputTokens: 100, outputTokens: 50, turn: 2),
            duration: 1500
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

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
        // Given - streaming was finalized before turn end (e.g., before capability invocation)
        let firstTextId = UUID()
        mockContext.streamingMessageId = nil
        mockContext.firstTextMessageIdForTurn = firstTextId
        mockContext.currentModel = "claude-3-opus"
        mockContext.messages = [
            ChatMessage(id: firstTextId, role: .assistant, content: .text("response"))
        ]

        // When
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 1,
            tokenRecord: makeTokenRecord(inputTokens: 100, outputTokens: 50),
            duration: 1000
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

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
        let tokenRecord = makeTokenRecord(
            inputTokens: 1500,
            outputTokens: 200,
            contextWindow: 1000,
            newInput: 500
        )
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 1,
            tokenRecord: tokenRecord,
            duration: 1000
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

        // Then
        let record = mockContext.messages[0].tokenRecord
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.computed.newInputTokens, 500)
        XCTAssertEqual(record?.source.rawOutputTokens, 200)
        XCTAssertEqual(record?.computed.contextWindowTokens, 1000)
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
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 1,
            tokenRecord: tokenRecord,
            duration: 1000
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

        // Then
        XCTAssertTrue(mockContext.contextStateUpdateFromTokenRecordCalled)
    }

    func testTurnEndUpdatesContextLimit() {
        // When
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 1,
            contextLimit: 200000,
            duration: 1000
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

        // Then
        XCTAssertEqual(mockContext.contextStateCurrentContextWindow, 200000)
    }

    func testTurnEndFallsBackToCapabilityInvocationMessageWhenNoTextExists() {
        // Given - intermediate turn: [thinking, capability_invocation] with NO visible text
        // streamingMessageId and firstTextMessageIdForTurn are both nil
        mockContext.streamingMessageId = nil
        mockContext.firstTextMessageIdForTurn = nil
        mockContext.turnStartMessageIndex = 0
        mockContext.currentModel = "claude-opus-4-6"

        let capabilityInvocationMessage = ChatMessage(
            role: .assistant,
            content: .capabilityInvocation(testCapabilityInvocation(id: "tc-1", status: .running))
        )
        mockContext.messages = [capabilityInvocationMessage]

        // When
        let tokenRecord = makeTokenRecord(inputTokens: 100, outputTokens: 50)
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 1,
            stopReason: "capability_invocation",
            tokenRecord: tokenRecord,
            duration: 500
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

        // Then - should find the capabilityInvocation message via last-message search
        XCTAssertNotNil(mockContext.messages[0].tokenRecord)
        XCTAssertEqual(mockContext.messages[0].tokenRecord?.source.rawInputTokens, 100)
        XCTAssertEqual(mockContext.messages[0].turnNumber, 1)
    }

    func testTurnEndAssignsMetadataToLastMessageInTurn() {
        // Given - turn has [capabilityInvocation, text] — last message is text
        mockContext.streamingMessageId = nil
        mockContext.firstTextMessageIdForTurn = nil
        mockContext.turnStartMessageIndex = 0
        mockContext.currentModel = "claude-opus-4-6"

        let capabilityInvocationMessage = ChatMessage(
            role: .assistant,
            content: .capabilityInvocation(testCapabilityInvocation(id: "tc-1", status: .success))
        )
        let textMessage = ChatMessage(role: .assistant, content: .text("some response"))
        mockContext.messages = [capabilityInvocationMessage, textMessage]

        // When
        let tokenRecord = makeTokenRecord(inputTokens: 200, outputTokens: 100)
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 1,
            tokenRecord: tokenRecord,
            duration: 800
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

        // Then - stats go on the last message (text at index 1)
        XCTAssertNil(mockContext.messages[0].tokenRecord)
        XCTAssertNotNil(mockContext.messages[1].tokenRecord)
    }

    func testTurnEndAssignsMetadataToLastCapabilityInParallelCapabilities() {
        // Given - turn with [text, invocation1, invocation2, invocation3] — parallel capability invocations
        // This is the bug case: stats must go on the LAST capability, not the text or first capability
        mockContext.streamingMessageId = nil
        mockContext.firstTextMessageIdForTurn = nil
        mockContext.turnStartMessageIndex = 0
        mockContext.currentModel = "claude-opus-4-6"

        let textMessage = ChatMessage(role: .assistant, content: .text("Let me search for that."))
        let invocation1 = ChatMessage(role: .assistant, content: .capabilityInvocation(testCapabilityInvocation(id: "tc-1", status: .success)))
        let invocation2 = ChatMessage(role: .assistant, content: .capabilityInvocation(testCapabilityInvocation(id: "tc-2", status: .success)))
        let invocation3 = ChatMessage(role: .assistant, content: .capabilityInvocation(testCapabilityInvocation(id: "tc-3", status: .success)))
        mockContext.messages = [textMessage, invocation1, invocation2, invocation3]

        // When
        let tokenRecord = makeTokenRecord(inputTokens: 500, outputTokens: 200)
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 1,
            stopReason: "capability_invocation",
            tokenRecord: tokenRecord,
            duration: 1200
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

        // Then - stats must go on the LAST capability (index 3), not text or first capability
        XCTAssertNil(mockContext.messages[0].tokenRecord)  // text — no stats
        XCTAssertNil(mockContext.messages[1].tokenRecord)  // invocation1 — no stats
        XCTAssertNil(mockContext.messages[2].tokenRecord)  // invocation2 — no stats
        XCTAssertNotNil(mockContext.messages[3].tokenRecord)  // invocation3 — stats here
        XCTAssertEqual(mockContext.messages[3].model, "claude-opus-4-6")
        XCTAssertEqual(mockContext.messages[3].latencyMs, 1200)
    }

    func testTurnEndAssignsMetadataToLastCapabilityInCapabilityOnlyTurn() {
        // Given - capability-only turn: [invocation1, invocation2] — no text at all
        mockContext.streamingMessageId = nil
        mockContext.firstTextMessageIdForTurn = nil
        mockContext.turnStartMessageIndex = 0
        mockContext.currentModel = "claude-opus-4-6"

        let invocation1 = ChatMessage(role: .assistant, content: .capabilityInvocation(testCapabilityInvocation(id: "tc-1", status: .success)))
        let invocation2 = ChatMessage(role: .assistant, content: .capabilityInvocation(testCapabilityInvocation(id: "tc-2", status: .success)))
        mockContext.messages = [invocation1, invocation2]

        // When
        let tokenRecord = makeTokenRecord(inputTokens: 300, outputTokens: 100)
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 2,
            stopReason: "capability_invocation",
            tokenRecord: tokenRecord,
            duration: 600
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

        // Then - stats go on the last capability (index 1)
        XCTAssertNil(mockContext.messages[0].tokenRecord)
        XCTAssertNotNil(mockContext.messages[1].tokenRecord)
        XCTAssertEqual(mockContext.messages[1].tokenRecord?.source.rawInputTokens, 300)
    }

    func testTurnEndClearsTurnTracking() {
        // Given
        mockContext.turnStartMessageIndex = 5
        mockContext.firstTextMessageIdForTurn = UUID()

        // When
        let pluginResult = makeTurnEndPluginResult(turnNumber: 1, duration: 1000)
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

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
        XCTAssertTrue(mockContext.animationCoordinatorResetCapabilityStateCalled)
        XCTAssertTrue(mockContext.streamingManagerResetCalled)
    }

    func testCompleteDoesNotSetAgentPhaseDirectly() {
        // The coordinator should NOT modify agentPhase; ChatViewModel owns the
        // terminal transition after the coordinator clears streaming state.
        mockContext.agentPhase = .processing

        coordinator.handleComplete(streamingText: "", context: mockContext)

        // agentPhase must remain unchanged by the coordinator
        XCTAssertEqual(mockContext.agentPhase, .processing)
    }

    func testCompleteClearsCapabilityTracking() {
        // Given
        mockContext.currentCapabilityInvocationMessages = [UUID(): makeTextMessage("test")]
        mockContext.currentTurnCapabilityInvocations = [
            CapabilityInvocationRecord(invocationId: "invocation1", modelPrimitiveName: "execute", arguments: "{}")
        ]

        // When
        coordinator.handleComplete(streamingText: "", context: mockContext)

        // Then
        XCTAssertTrue(mockContext.currentCapabilityInvocationMessages.isEmpty)
        XCTAssertTrue(mockContext.currentTurnCapabilityInvocations.isEmpty)
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

    private func makeTurnEndPluginResult(
        turnNumber: Int,
        stopReason: String = "end_turn",
        tokenRecord: TokenRecord? = nil,
        contextLimit: Int? = nil,
        cost: Double? = nil,
        duration: Int? = nil
    ) -> TurnEndPlugin.Result {
        TurnEndPlugin.Result(
            turnNumber: turnNumber,
            duration: duration,
            tokenRecord: tokenRecord,
            stopReason: stopReason,
            cost: cost,
            contextLimit: contextLimit
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
    let messageIndex = MessageIndex()
    var currentCapabilityInvocationMessages: [UUID: ChatMessage] = [:]
    var currentTurnCapabilityInvocations: [CapabilityInvocationRecord] = []
    var thinkingMessageId: UUID?
    var turnStartMessageIndex: Int?
    var firstTextMessageIdForTurn: UUID?
    var streamingMessageId: UUID?
    var streamingText: String = ""
    var hasActiveStreaming: Bool = false
    var currentModel: String = "claude-3-sonnet"
    var agentPhase: AgentPhase = .idle
    // catchingUpMessageId removed — replaced by sequence-based reconstruction
    var sessionId: String = "test-session"

    // Context state tracking
    var contextStateCurrentContextWindow: Int = 0
    var contextStateUpdateFromTokenRecordCalled = false

    // MARK: - Call tracking
    var flushPendingTextUpdatesCalled = false
    var finalizeStreamingMessageCalled = false
    var thinkingStateStartTurnCalled: Int?
    var thinkingStateModelUsed: String?
    var enqueuedTurnBoundary: UIUpdateQueue.TurnBoundaryData?
    var animationCoordinatorResetCapabilityStateCalled = false
    var uiUpdateQueueFlushCalled = false
    var uiUpdateQueueResetCalled = false
    var streamingManagerResetCalled = false
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

    func resetAnimationCoordinatorCapabilityState() {
        animationCoordinatorResetCapabilityStateCalled = true
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

    func updateSessionDashboardInfo(lastAssistantResponse: String?) {
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
