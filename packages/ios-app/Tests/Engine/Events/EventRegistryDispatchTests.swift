import XCTest
@testable import TronMobile

/// Tests that EventRegistry routes plugin events to their handlers.
@MainActor
final class EventRegistryDispatchTests: XCTestCase {

    var registry: EventRegistry!
    var mockContext: MockEventDispatchContext!

    override func setUp() async throws {
        registry = EventRegistry()
        mockContext = MockEventDispatchContext()
        registry.registerAll()
    }

    override func tearDown() async throws {
        registry = nil
        mockContext = nil
    }

    // MARK: - Text/Thinking Event Tests

    func testDispatch_textDelta_callsHandleTextDelta() {
        // Given: A text delta result
        let result = TextDeltaPlugin.Result(delta: "Hello world", messageIndex: nil)

        // When: Dispatching
        registry.dispatch(
            type: TextDeltaPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called with correct delta
        XCTAssertEqual(mockContext.handleTextDeltaCalledWith, "Hello world")
    }

    func testDispatch_thinkingDelta_callsHandleThinkingDelta() {
        // Given: A thinking delta result
        let result = ThinkingDeltaPlugin.Result(delta: "Let me think...", kind: .thinking)

        // When: Dispatching
        registry.dispatch(
            type: ThinkingDeltaPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called with correct delta
        XCTAssertEqual(mockContext.handleThinkingDeltaCalledWith, "Let me think...")
        XCTAssertEqual(mockContext.handleThinkingDeltaKindCalledWith, .thinking)
    }

    func testDispatch_thinkingEnd_callsHandleThinkingEnd() {
        let result = ThinkingEndPlugin.Result(thinking: "Final thinking snapshot", kind: .thinking)

        registry.dispatch(
            type: ThinkingEndPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        XCTAssertEqual(mockContext.handleThinkingEndCalledWith, "Final thinking snapshot")
        XCTAssertEqual(mockContext.handleThinkingEndKindCalledWith, .thinking)
    }

    // MARK: - Capability Event Tests

    func testDispatch_capabilityInvocationStarted_callsHandleCapabilityInvocationStart() {
        // Given: A capability start result
        let result = CapabilityInvocationStartedPlugin.Result(
            modelPrimitiveName: "execute",
            invocationId: "inv_123",
            arguments: nil
        )

        // When: Dispatching
        registry.dispatch(
            type: CapabilityInvocationStartedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleCapabilityInvocationStartedCalledWith?.invocationId, "inv_123")
        XCTAssertEqual(mockContext.handleCapabilityInvocationStartedCalledWith?.modelPrimitiveName, "execute")
    }

    func testDispatch_capabilityInvocationCompleted_callsHandleCapabilityInvocationEnd() {
        // Given: A capability end result
        let result = CapabilityInvocationCompletedPlugin.Result(
            invocationId: "inv_123",
            modelPrimitiveName: "execute",
            isError: false,
            content: "file contents",
            duration: 150,
            details: nil,
            rawDetails: nil
        )

        // When: Dispatching
        registry.dispatch(
            type: CapabilityInvocationCompletedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleCapabilityInvocationCompletedCalledWith?.invocationId, "inv_123")
        XCTAssertEqual(mockContext.handleCapabilityInvocationCompletedCalledWith?.duration, 150)
    }

    // MARK: - Turn Lifecycle Event Tests

    func testDispatch_turnStart_callsHandleTurnStart() {
        // Given: A turn start result
        let result = TurnStartPlugin.Result(turnNumber: 1, agentPhase: "processing")

        // When: Dispatching
        registry.dispatch(
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
            contextLimit: nil,
            model: nil
        )

        // When: Dispatching
        registry.dispatch(
            type: TurnEndPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleTurnEndCalledWith?.turnNumber, 1)
    }

    func testDispatch_turnFailed_callsHandleTurnFailed() {
        let failure = CanonicalFailurePayload(
            code: "RUNTIME_CANCELLED",
            category: "cancelled",
            message: "Interrupted by user",
            retryable: false,
            recoverable: true,
            origin: "agent_runtime"
        )
        let result = TurnFailedPlugin.Result(
            turn: 1,
            error: failure.message,
            code: failure.code,
            category: failure.category,
            retryable: failure.retryable,
            recoverable: failure.recoverable,
            origin: failure.origin,
            details: ["failure": AnyCodable(failure.asDetails.mapValues(\.value))],
            failure: failure,
            partialContent: "partial response"
        )

        registry.dispatch(
            type: TurnFailedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        XCTAssertEqual(mockContext.handleTurnFailedCalledWith?.turn, 1)
        XCTAssertTrue(mockContext.handleTurnFailedCalledWith?.isCancellation == true)
    }

    func testDispatch_responseComplete_callsHandleResponseComplete() {
        let result = AgentResponseCompletePlugin.Result(
            turnNumber: 2,
            hasCapabilityInvocations: false,
            capabilityInvocationCount: 0
        )

        registry.dispatch(
            type: AgentResponseCompletePlugin.eventType,
            transform: { result },
            context: mockContext
        )

        XCTAssertEqual(mockContext.handleResponseCompleteCalledWith?.turnNumber, 2)
        XCTAssertEqual(
            mockContext.handleResponseCompleteCalledWith?.hasCapabilityInvocations,
            false
        )
    }

    func testDispatch_complete_callsHandleComplete() {
        // Given: A complete result
        let result = CompletePlugin.Result(success: true, totalTokens: nil, totalTurns: nil)

        // When: Dispatching
        registry.dispatch(
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
        registry.dispatch(
            type: AgentReadyPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertTrue(mockContext.handleAgentReadyCalled)
    }

    func testDispatch_error_callsHandleProviderError() {
        // Given: An error result with no enrichment.
        let result = ErrorPlugin.Result(
            code: "ERROR",
            message: "Something went wrong",
            provider: nil,
            category: nil,
            suggestion: nil,
            retryable: nil,
            recoverable: nil,
            origin: nil,
            details: nil,
            retryAfterMs: nil,
            statusCode: nil,
            errorType: nil,
            model: nil,
            failure: nil
        )

        // When: Dispatching
        registry.dispatch(
            type: ErrorPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called with provider error result
        XCTAssertEqual(mockContext.handleProviderErrorCalledWith?.message, "Something went wrong")
        XCTAssertNil(mockContext.handleProviderErrorCalledWith?.category)
    }

    func testDispatch_enrichedError_callsHandleProviderErrorWithCategory() {
        // Given: An enriched error result with category and suggestion
        let result = ErrorPlugin.Result(
            code: "AUTHENTICATION",
            message: "Invalid API key",
            provider: "anthropic",
            category: "authentication",
            suggestion: "Run tron login to re-authenticate",
            retryable: false,
            recoverable: true,
            origin: "model_provider",
            details: nil,
            retryAfterMs: nil,
            statusCode: 401,
            errorType: "authentication_error",
            model: "claude-sonnet-4-20250514",
            failure: nil
        )

        // When: Dispatching
        registry.dispatch(
            type: ErrorPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called with enriched provider error
        XCTAssertEqual(mockContext.handleProviderErrorCalledWith?.category, "authentication")
        XCTAssertEqual(mockContext.handleProviderErrorCalledWith?.provider, "anthropic")
        XCTAssertEqual(mockContext.handleProviderErrorCalledWith?.suggestion, "Run tron login to re-authenticate")
        XCTAssertEqual(mockContext.handleProviderErrorCalledWith?.retryable, false)
    }

    // MARK: - Context Operation Event Tests

    func testDispatch_compaction_callsHandleCompaction() {
        // Given: A compaction result
        let result = CompactionPlugin.Result(
            success: true,
            tokensBefore: 50000,
            tokensAfter: 30000,
            compressionRatio: 0.6,
            reason: "Context limit approaching",
            summary: "Summarized conversation history",
            estimatedContextTokens: nil,
            preservedTurns: nil,
            summarizedTurns: nil
        )

        // When: Dispatching
        registry.dispatch(
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
        registry.dispatch(
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
        registry.dispatch(
            type: MessageDeletedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: Handler should be called
        XCTAssertEqual(mockContext.handleMessageDeletedCalledWith?.targetEventId, "event_123")
    }

    // MARK: - Edge Case Tests

    func testDispatch_streamRecoveryRequired_callsContinuityHandler() {
        let result = StreamRecoveryRequiredPlugin.Result(
            reason: "client_buffer_overflow",
            droppedEventCount: 2
        )

        registry.dispatch(
            type: StreamRecoveryRequiredPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        XCTAssertEqual(mockContext.handleStreamRecoveryRequiredCalledWith?.reason, "client_buffer_overflow")
        XCTAssertEqual(mockContext.handleStreamRecoveryRequiredCalledWith?.droppedEventCount, 2)
    }

    func testDispatch_registeredNilTransformIsNoOpWithoutWarning() {
        // Given: A registered plugin whose transform returns nil
        let nilTransform: @Sendable () -> (any EventResult)? = { nil }

        // When: Dispatching
        registry.dispatch(
            type: AgentResponseCompletePlugin.eventType,
            transform: nilTransform,
            context: mockContext
        )

        // Then: nil transform is an intentional no-op
        XCTAssertFalse(mockContext.logWarningCalled)
        XCTAssertFalse(mockContext.logDebugCalled)
    }

    func testDispatch_markerNoOpEventsDoNotLogWarnings() {
        for eventType in [
            AgentStartPlugin.eventType,
            ThinkingStartPlugin.eventType,
            CapabilityInvocationBatchPlugin.eventType
        ] {
            mockContext.resetLogs()

            registry.dispatch(
                type: eventType,
                transform: { nil },
                context: mockContext
            )

            XCTAssertFalse(mockContext.logWarningCalled, "\(eventType) should be a no-op")
            XCTAssertFalse(mockContext.logDebugCalled, "\(eventType) should be a no-op")
        }
    }

    func testDispatch_unknownType_logsDebug() {
        // Given: An unknown event type
        let result = TextDeltaPlugin.Result(delta: "test", messageIndex: nil)

        // When: Dispatching unknown type
        registry.dispatch(
            type: "unknown.event.type",
            transform: { result },
            context: mockContext
        )

        XCTAssertEqual(
            mockContext.logDebugCalledWith,
            "No plugin registered for event type: unknown.event.type"
        )
    }

    func testDispatch_connectedEvent_ignored() {
        // Given: A connected event result
        let result = ConnectedPlugin.Result(serverId: nil, version: nil, clientId: nil)

        // When: Dispatching
        registry.dispatch(
            type: ConnectedPlugin.eventType,
            transform: { result },
            context: mockContext
        )

        // Then: No handler should be called (ConnectedPlugin is not dispatchable)
        XCTAssertFalse(mockContext.handleCompleteCalled)
        XCTAssertNil(mockContext.handleTextDeltaCalledWith)
        // ConnectedPlugin's box returns false from dispatch → logged as unhandled
        XCTAssertEqual(
            mockContext.logDebugCalledWith,
            "Unhandled plugin event type: \(ConnectedPlugin.eventType)"
        )
    }
}

// MARK: - Mock Context

/// Mock implementation of EventDispatchTarget for testing
@MainActor
final class MockEventDispatchContext: EventDispatchTarget {
    // MARK: - Text/Thinking
    var handleTextDeltaCalledWith: String?
    var handleThinkingDeltaCalledWith: String?
    var handleThinkingDeltaKindCalledWith: ThinkingDisplayKind?
    var handleThinkingEndCalledWith: String?
    var handleThinkingEndKindCalledWith: ThinkingDisplayKind?

    // MARK: - Capabilities
    var handleCapabilityInvocationGeneratingCalledWith: CapabilityInvocationGeneratingPlugin.Result?
    var handleCapabilityInvocationStartedCalledWith: CapabilityInvocationStartedPlugin.Result?
    var handleCapabilityInvocationProgressCalledWith: CapabilityInvocationProgressPlugin.Result?
    var handleCapabilityInvocationCompletedCalledWith: CapabilityInvocationCompletedPlugin.Result?
    var handleCapabilityRunStatusCalledWith: CapabilityRunStatusPlugin.Result?

    // MARK: - Turn Lifecycle
    var handleTurnStartCalledWith: TurnStartPlugin.Result?
    var handleResponseCompleteCalledWith: AgentResponseCompletePlugin.Result?
    var handleTurnEndCalledWith: TurnEndPlugin.Result?
    var handleTurnFailedCalledWith: TurnFailedPlugin.Result?
    var handleCompleteCalled = false
    var handleAgentErrorCalledWith: String?
    var handleProviderErrorCalledWith: ErrorPlugin.Result?

    // MARK: - Context Operations
    var handleCompactionCalledWith: CompactionPlugin.Result?
    var handleContextClearedCalledWith: ContextClearedPlugin.Result?
    var handleMessageDeletedCalledWith: MessageDeletedPlugin.Result?

    // MARK: - Logging
    var logWarningCalled = false
    var logDebugCalled = false
    var logDebugCalledWith: String?

    // MARK: - Protocol Implementation

    func handleTextDelta(_ delta: String) {
        handleTextDeltaCalledWith = delta
    }

    func handleThinkingDelta(_ delta: String, kind: ThinkingDisplayKind) {
        handleThinkingDeltaCalledWith = delta
        handleThinkingDeltaKindCalledWith = kind
    }

    func handleThinkingEnd(_ thinking: String, kind: ThinkingDisplayKind) {
        handleThinkingEndCalledWith = thinking
        handleThinkingEndKindCalledWith = kind
    }

    func handleCapabilityInvocationGenerating(_ result: CapabilityInvocationGeneratingPlugin.Result) {
        handleCapabilityInvocationGeneratingCalledWith = result
    }

    func handleCapabilityInvocationStarted(_ result: CapabilityInvocationStartedPlugin.Result) {
        handleCapabilityInvocationStartedCalledWith = result
    }

    func handleCapabilityInvocationOutput(_ result: CapabilityInvocationOutputPlugin.Result) {}

    func handleCapabilityInvocationProgress(_ result: CapabilityInvocationProgressPlugin.Result) {
        handleCapabilityInvocationProgressCalledWith = result
    }

    func handleCapabilityInvocationCompleted(_ result: CapabilityInvocationCompletedPlugin.Result) {
        handleCapabilityInvocationCompletedCalledWith = result
    }

    func handleCapabilityRunStatus(_ result: CapabilityRunStatusPlugin.Result) {
        handleCapabilityRunStatusCalledWith = result
    }

    func handleTurnStart(_ result: TurnStartPlugin.Result) {
        handleTurnStartCalledWith = result
    }

    func handleResponseComplete(_ result: AgentResponseCompletePlugin.Result) {
        handleResponseCompleteCalledWith = result
    }

    func handleTurnEnd(_ result: TurnEndPlugin.Result) {
        handleTurnEndCalledWith = result
    }

    func handleTurnFailed(_ result: TurnFailedPlugin.Result) {
        handleTurnFailedCalledWith = result
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

    func handleProviderError(_ result: ErrorPlugin.Result) {
        handleProviderErrorCalledWith = result
    }

    var handleCompactionStartedCalledWith: CompactionStartedPlugin.Result?
    func handleCompactionStarted(_ result: CompactionStartedPlugin.Result) {
        handleCompactionStartedCalledWith = result
    }

    func handleCompaction(_ result: CompactionPlugin.Result) {
        handleCompactionCalledWith = result
    }

    func handleContextCleared(_ result: ContextClearedPlugin.Result) {
        handleContextClearedCalledWith = result
    }

    func handleMessageDeleted(_ result: MessageDeletedPlugin.Result) {
        handleMessageDeletedCalledWith = result
    }

    // MARK: - Server
    var handleServerRestartingCalledWith: ServerRestartingPlugin.Result?
    func handleServerRestarting(_ result: ServerRestartingPlugin.Result) {
        handleServerRestartingCalledWith = result
    }

    var handleStreamRecoveryRequiredCalledWith: StreamRecoveryRequiredPlugin.Result?
    func handleStreamRecoveryRequired(_ result: StreamRecoveryRequiredPlugin.Result) {
        handleStreamRecoveryRequiredCalledWith = result
    }

    func logWarning(_ message: String) {
        logWarningCalled = true
    }

    func logDebug(_ message: String) {
        logDebugCalled = true
        logDebugCalledWith = message
    }

    func resetLogs() {
        logWarningCalled = false
        logDebugCalled = false
        logDebugCalledWith = nil
    }
}
