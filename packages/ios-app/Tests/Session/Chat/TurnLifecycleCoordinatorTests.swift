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
        mockContext.currentTurnCapabilityMessageIds = [UUID()]

        // When
        let pluginResult = TurnStartPlugin.Result(turnNumber: 2, agentPhase: "processing")
        coordinator.handleTurnStart(pluginResult, context: mockContext)

        // Then
        XCTAssertTrue(mockContext.currentTurnCapabilityMessageIds.isEmpty)
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
            ChatMessage(
                id: thinkingId,
                role: .assistant,
                content: .thinking(
                    visible: "thinking...",
                    isExpanded: false,
                    isStreaming: true,
                    kind: .thinking
                )
            )
        ]

        // When
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 1,
            tokenRecord: makeTokenRecord(inputTokens: 100, outputTokens: 50),
            duration: 1000
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

        // Then
        if case .thinking(_, _, let isStreaming, _) = mockContext.messages[0].content {
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
        markResponseComplete(turnNumber: 2, hasCapabilityInvocations: false)

        // When
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 2,
            tokenRecord: makeTokenRecord(inputTokens: 100, outputTokens: 50, turn: 2),
            model: "server-final-model",
            duration: 1500
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

        // Then
        let msg = mockContext.messages[0]
        XCTAssertEqual(msg.tokenRecord?.source.rawInputTokens, 100)
        XCTAssertEqual(msg.tokenRecord?.source.rawOutputTokens, 50)
        XCTAssertEqual(msg.model, "server-final-model")
        XCTAssertEqual(msg.latencyMs, 1500)
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
        markResponseComplete(turnNumber: 1, hasCapabilityInvocations: false)

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
        markResponseComplete(turnNumber: 1, hasCapabilityInvocations: false)

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

    func testCapabilityResponseDoesNotAttachMetadataToInvocation() {
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
        markResponseComplete(turnNumber: 1, hasCapabilityInvocations: true)

        // When
        let tokenRecord = makeTokenRecord(inputTokens: 100, outputTokens: 50)
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 1,
            stopReason: "capability_invocation",
            tokenRecord: tokenRecord,
            duration: 500
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

        // Then - capability items never own a response metadata row.
        XCTAssertNil(mockContext.messages[0].tokenRecord)
        XCTAssertNil(mockContext.messages[0].model)
        XCTAssertNil(mockContext.messages[0].latencyMs)
        XCTAssertEqual(mockContext.messages[0].turnNumber, 1)
    }

    func testFinalResponseMetadataTargetsTextInsteadOfThinking() {
        // Given - a terminal turn has thinking followed by response text.
        mockContext.streamingMessageId = nil
        let textId = UUID()
        mockContext.firstTextMessageIdForTurn = textId
        mockContext.turnStartMessageIndex = 0
        mockContext.currentModel = "claude-opus-4-6"

        let thinkingMessage = ChatMessage(
            role: .assistant,
            content: .thinking(
                visible: "Checking the result",
                isExpanded: false,
                isStreaming: false,
                kind: .thinking
            )
        )
        let textMessage = ChatMessage(id: textId, role: .assistant, content: .text("some response"))
        mockContext.messages = [thinkingMessage, textMessage]
        markResponseComplete(turnNumber: 1, hasCapabilityInvocations: false)

        // When
        let tokenRecord = makeTokenRecord(inputTokens: 200, outputTokens: 100)
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 1,
            tokenRecord: tokenRecord,
            duration: 800
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

        // Then - only the explicitly marked response text owns metadata.
        XCTAssertNil(mockContext.messages[0].tokenRecord)
        XCTAssertNotNil(mockContext.messages[1].tokenRecord)
        XCTAssertNil(mockContext.messages[1].model)
        XCTAssertTrue(mockContext.messages[1].isFinalAssistantResponse)
    }

    func testCapabilityBearingResponseSuppressesMetadataEvenWithEndTurnStopReason() {
        // Given - provider stop reason says end_turn, but the exact response
        // contract reports capability invocations.
        mockContext.streamingMessageId = nil
        mockContext.firstTextMessageIdForTurn = nil
        mockContext.turnStartMessageIndex = 0
        mockContext.currentModel = "claude-opus-4-6"

        let textMessage = ChatMessage(role: .assistant, content: .text("Let me search for that."))
        let invocation1 = ChatMessage(role: .assistant, content: .capabilityInvocation(testCapabilityInvocation(id: "tc-1", status: .success)))
        let invocation2 = ChatMessage(role: .assistant, content: .capabilityInvocation(testCapabilityInvocation(id: "tc-2", status: .success)))
        let invocation3 = ChatMessage(role: .assistant, content: .capabilityInvocation(testCapabilityInvocation(id: "tc-3", status: .success)))
        mockContext.messages = [textMessage, invocation1, invocation2, invocation3]
        markResponseComplete(turnNumber: 1, hasCapabilityInvocations: true, capabilityInvocationCount: 3)

        // When
        let tokenRecord = makeTokenRecord(inputTokens: 500, outputTokens: 200)
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 1,
            stopReason: "end_turn",
            tokenRecord: tokenRecord,
            duration: 1200
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

        // Then - neither intermediate text nor any invocation gets metadata.
        for message in mockContext.messages {
            XCTAssertNil(message.tokenRecord)
            XCTAssertNil(message.model)
            XCTAssertNil(message.latencyMs)
            XCTAssertFalse(message.isFinalAssistantResponse)
        }
    }

    func testCapabilityOnlyTurnHasNoPresentationMetadata() {
        // Given - capability-only turn: [invocation1, invocation2] — no text at all
        mockContext.streamingMessageId = nil
        mockContext.firstTextMessageIdForTurn = nil
        mockContext.turnStartMessageIndex = 0
        mockContext.currentModel = "claude-opus-4-6"

        let invocation1 = ChatMessage(role: .assistant, content: .capabilityInvocation(testCapabilityInvocation(id: "tc-1", status: .success)))
        let invocation2 = ChatMessage(role: .assistant, content: .capabilityInvocation(testCapabilityInvocation(id: "tc-2", status: .success)))
        mockContext.messages = [invocation1, invocation2]
        markResponseComplete(turnNumber: 2, hasCapabilityInvocations: true, capabilityInvocationCount: 2)

        // When
        let tokenRecord = makeTokenRecord(inputTokens: 300, outputTokens: 100)
        let pluginResult = makeTurnEndPluginResult(
            turnNumber: 2,
            stopReason: "capability_invocation",
            tokenRecord: tokenRecord,
            duration: 600
        )
        coordinator.handleTurnEnd(pluginResult, context: mockContext)

        // Then - capability-only turns have no final textual response footer.
        XCTAssertNil(mockContext.messages[0].tokenRecord)
        XCTAssertNil(mockContext.messages[1].tokenRecord)
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
        mockContext.currentTurnCapabilityMessageIds = [UUID()]

        // When
        coordinator.handleComplete(streamingText: "", context: mockContext)

        // Then
        XCTAssertTrue(mockContext.currentTurnCapabilityMessageIds.isEmpty)
    }

    // MARK: - Helpers

    private func makeTurnEndPluginResult(
        turnNumber: Int,
        stopReason: String = "end_turn",
        tokenRecord: TokenRecord? = nil,
        contextLimit: Int? = nil,
        cost: Double? = nil,
        model: String? = nil,
        duration: Int? = nil
    ) -> TurnEndPlugin.Result {
        TurnEndPlugin.Result(
            turnNumber: turnNumber,
            duration: duration,
            tokenRecord: tokenRecord,
            stopReason: stopReason,
            cost: cost,
            contextLimit: contextLimit,
            model: model
        )
    }

    private func markResponseComplete(
        turnNumber: Int,
        hasCapabilityInvocations: Bool,
        capabilityInvocationCount: Int? = nil
    ) {
        coordinator.handleResponseComplete(
            AgentResponseCompletePlugin.Result(
                turnNumber: turnNumber,
                hasCapabilityInvocations: hasCapabilityInvocations,
                capabilityInvocationCount: capabilityInvocationCount ?? (hasCapabilityInvocations ? 1 : 0)
            ),
            context: mockContext
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
    var currentTurnCapabilityMessageIds: Set<UUID> = []
    var thinkingMessageId: UUID?
    var turnStartMessageIndex: Int?
    var firstTextMessageIdForTurn: UUID?
    var streamingMessageId: UUID?
    var hasActiveStreaming: Bool = false
    var currentModel: String = "claude-3-sonnet"
    var agentPhase: AgentPhase = .idle
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

    func updateContextStateFromTokenRecord(_ record: TokenRecord) {
        contextStateUpdateFromTokenRecordCalled = true
    }

    func setContextStateCurrentContextWindow(_ limit: Int) {
        contextStateCurrentContextWindow = limit
    }

    func accumulateTokens(input: Int, output: Int, cacheRead: Int, cacheCreation: Int, cost: Double) {
        // No-op for mock
    }

    func persistAccumulatedSessionTokens(lastTurnInputTokens: Int) async throws {
        // No-op for mock
    }

    func setSessionProcessing(_ isProcessing: Bool) {
        // No-op for mock
    }

    func updateSessionActivitySummary(lastAssistantResponse: String?) {
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
