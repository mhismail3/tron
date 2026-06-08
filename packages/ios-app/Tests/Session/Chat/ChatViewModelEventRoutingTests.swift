import XCTest
@testable import TronMobile

/// Integration tests for ChatViewModel event routing.
/// These tests verify that events flow correctly from handlers to coordinators and state.
///
/// Following TDD - tests written FIRST to define expected behavior.
@MainActor
final class ChatViewModelEventRoutingTests: XCTestCase {

    // MARK: - Test Infrastructure

    private var viewModel: ChatViewModel!

    override func setUp() async throws {
        // Create minimal engine client for testing
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

    // MARK: - Helper Functions

    private func makeCapabilityInvocationStartResult(
        modelPrimitiveName: String,
        invocationId: String,
        arguments: [String: AnyCodable]? = nil,
        identity: CapabilityIdentity? = nil
    ) -> CapabilityInvocationStartedPlugin.Result {
        CapabilityInvocationStartedPlugin.Result(
            modelPrimitiveName: modelPrimitiveName,
            invocationId: invocationId,
            arguments: arguments,
            identity: identity
        )
    }

    private func makeCapabilityInvocationEndResult(
        invocationId: String,
        success: Bool,
        result: String?,
        durationMs: Int? = nil
    ) -> CapabilityInvocationCompletedPlugin.Result {
        CapabilityInvocationCompletedPlugin.Result(
            invocationId: invocationId,
            modelPrimitiveName: nil,
            isError: !success,
            content: result ?? "",
            duration: durationMs,
            details: nil,
            rawDetails: nil
        )
    }

    private func makeTokenRecord(
        inputTokens: Int = 500,
        outputTokens: Int = 200,
        contextWindowTokens: Int = 5000,
        newInputTokens: Int? = nil,
        turn: Int = 1
    ) -> TokenRecord {
        TokenRecord(
            source: TokenSource(
                provider: "anthropic",
                timestamp: ISO8601DateFormatter().string(from: Date()),
                rawInputTokens: inputTokens,
                rawOutputTokens: outputTokens,
                rawCacheReadTokens: 0,
                rawCacheCreationTokens: 0
            ),
            computed: ComputedTokens(
                contextWindowTokens: contextWindowTokens,
                newInputTokens: newInputTokens ?? contextWindowTokens,
                previousContextBaseline: 0,
                calculationMethod: "anthropic_cache_aware"
            ),
            meta: TokenMeta(
                turn: turn,
                sessionId: "test-session",
                extractedAt: ISO8601DateFormatter().string(from: Date()),
                normalizedAt: ISO8601DateFormatter().string(from: Date())
            )
        )
    }

    private func makeTurnEndResult(
        turnNumber: Int = 1,
        duration: Int? = 1000,
        tokenRecord: TokenRecord? = nil,
        stopReason: String? = "end_turn",
        cost: Double? = nil,
        contextLimit: Int? = nil
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

    private func makeCompactionResult(
        success: Bool = true,
        tokensBefore: Int,
        tokensAfter: Int,
        reason: String = "context_limit",
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

    // MARK: - Text Delta Routing Tests

    func test_textDelta_routesToStreamingManager() {
        // Given
        let initialText = viewModel.streamingManager.streamingText

        // When - simulate text delta event
        viewModel.handleTextDelta("Hello, world!")

        // Then - streaming manager should have the text
        XCTAssertEqual(viewModel.streamingManager.streamingText, initialText + "Hello, world!")
    }

    func test_textDelta_multipleDeltas_accumulate() {
        // When
        viewModel.handleTextDelta("Hello, ")
        viewModel.handleTextDelta("world!")

        // Then
        XCTAssertEqual(viewModel.streamingManager.streamingText, "Hello, world!")
    }

    // MARK: - Thinking Delta Routing Tests

    func test_thinkingDelta_createsThinkingMessage() {
        // Given
        XCTAssertNil(viewModel.thinkingMessageId)
        let initialCount = viewModel.messages.count

        // When
        viewModel.handleThinkingDelta("Thinking about the problem...")

        // Then - thinking message should be created
        XCTAssertNotNil(viewModel.thinkingMessageId)
        XCTAssertEqual(viewModel.messages.count, initialCount + 1)

        // And it should be a thinking message
        if let lastMessage = viewModel.messages.last,
           case .thinking(let visible, _, let isStreaming) = lastMessage.content {
            XCTAssertTrue(visible.contains("Thinking"))
            XCTAssertTrue(isStreaming)
        } else {
            XCTFail("Expected thinking message")
        }
    }

    func test_thinkingDelta_updatesExistingThinkingMessage() {
        // Given - create initial thinking message
        viewModel.handleThinkingDelta("First thought...")

        let thinkingId = viewModel.thinkingMessageId
        XCTAssertNotNil(thinkingId)

        // When - add more thinking
        viewModel.handleThinkingDelta(" Second thought...")

        // Then - same message ID, but content updated
        XCTAssertEqual(viewModel.thinkingMessageId, thinkingId)

        if let thinkingMessage = viewModel.messages.first(where: { $0.id == thinkingId }),
           case .thinking(let visible, _, _) = thinkingMessage.content {
            XCTAssertTrue(visible.contains("First"))
            XCTAssertTrue(visible.contains("Second"))
        }
    }

    func test_thinkingDelta_routesToThinkingState() {
        // When
        viewModel.handleThinkingDelta("Deep thought...")

        // Then - ThinkingState should have the content
        XCTAssertTrue(viewModel.thinkingState.currentText.contains("Deep thought"))
    }

    // MARK: - Capability Start Routing Tests

    func test_capabilityInvocationStarted_createsCapabilityMessage() {
        // Given
        let initialCount = viewModel.messages.count
        let result = makeCapabilityInvocationStartResult(
            modelPrimitiveName: "execute",
            invocationId: "toolu_test123",
            arguments: ["command": AnyCodable("ls -la")]
        )

        // When
        viewModel.handleCapabilityInvocationStarted(result)

        // Then - capability message should be created
        XCTAssertEqual(viewModel.messages.count, initialCount + 1)
    }

    func test_capabilityInvocationStarted_tracksCapabilityInvocation() {
        // Given
        XCTAssertTrue(viewModel.currentTurnCapabilityInvocations.isEmpty)
        let result = makeCapabilityInvocationStartResult(
            modelPrimitiveName: "execute",
            invocationId: "toolu_read123",
            arguments: ["file_path": AnyCodable("/test.txt")]
        )

        // When
        viewModel.handleCapabilityInvocationStarted(result)

        // Then - capability invocation should be tracked
        XCTAssertEqual(viewModel.currentTurnCapabilityInvocations.count, 1)
        XCTAssertEqual(viewModel.currentTurnCapabilityInvocations.first?.invocationId, "toolu_read123")
        XCTAssertEqual(viewModel.currentTurnCapabilityInvocations.first?.modelPrimitiveName, "execute")
    }

    // MARK: - Capability Progress Routing Tests

    func test_capabilityProgress_updatesChipProgressFields() {
        let invocationId = "toolu_progress1"
        let startResult = makeCapabilityInvocationStartResult(
            modelPrimitiveName: "execute",
            invocationId: invocationId,
            arguments: ["command": AnyCodable("long-task")]
        )
        viewModel.handleCapabilityInvocationStarted(startResult)

        let progress = CapabilityInvocationProgressPlugin.Result(
            invocationId: invocationId,
            message: "downloading chunk 3/5",
            percent: 0.6
        )
        viewModel.handleCapabilityInvocationProgress(progress)

        guard let index = viewModel.messages.lastIndex(where: {
            if case .capabilityInvocation(let t) = $0.content { return t.id == invocationId }
            return false
        }) else { return XCTFail("Capability invocation message not found") }

        if case .capabilityInvocation(let capability) = viewModel.messages[index].content {
            XCTAssertEqual(capability.progressMessage, "downloading chunk 3/5")
            XCTAssertEqual(capability.progressPercent, 0.6)
        } else {
            XCTFail("Unexpected content type")
        }
    }

    func test_capabilityProgress_unknownInvocationId_isNoop() {
        let initialCount = viewModel.messages.count
        let progress = CapabilityInvocationProgressPlugin.Result(
            invocationId: "not-found",
            message: "ignored",
            percent: nil
        )
        viewModel.handleCapabilityInvocationProgress(progress)
        XCTAssertEqual(viewModel.messages.count, initialCount)
    }

    func test_capabilityInvocationCompleted_clearsProgressFields() {
        let invocationId = "toolu_progress_end"
        viewModel.handleCapabilityInvocationStarted(makeCapabilityInvocationStartResult(
            modelPrimitiveName: "execute",
            invocationId: invocationId,
            arguments: nil
        ))
        viewModel.handleCapabilityInvocationProgress(CapabilityInvocationProgressPlugin.Result(
            invocationId: invocationId,
            message: "in-flight",
            percent: 0.4
        ))
        viewModel.handleCapabilityInvocationCompleted(makeCapabilityInvocationEndResult(
            invocationId: invocationId,
            success: true,
            result: "done",
            durationMs: 10
        ))
        viewModel.flushUIUpdateQueue()

        guard let index = viewModel.messages.lastIndex(where: {
            if case .capabilityInvocation(let t) = $0.content { return t.id == invocationId }
            return false
        }) else { return XCTFail("Capability invocation message not found") }

        if case .capabilityInvocation(let capability) = viewModel.messages[index].content {
            XCTAssertNil(capability.progressMessage)
            XCTAssertNil(capability.progressPercent)
        }
    }

    // MARK: - Capability Completion Routing Tests

    func test_capabilityInvocationCompleted_updatesTrackedCapabilityInvocation() {
        // Given - start a capability first
        let invocationId = "toolu_test456"
        let startResult = makeCapabilityInvocationStartResult(
            modelPrimitiveName: "execute",
            invocationId: invocationId,
            arguments: ["command": AnyCodable("echo hello")]
        )
        viewModel.handleCapabilityInvocationStarted(startResult)

        // When - end the capability
        let endResult = makeCapabilityInvocationEndResult(
            invocationId: invocationId,
            success: true,
            result: "hello\n",
            durationMs: 50
        )
        viewModel.handleCapabilityInvocationCompleted(endResult)

        // Then - tracked capability invocation should have result
        if let record = viewModel.currentTurnCapabilityInvocations.first(where: { $0.invocationId == invocationId }) {
            XCTAssertEqual(record.result, "hello\n")
            XCTAssertFalse(record.isError)
        } else {
            XCTFail("Capability invocation record not found")
        }
    }

    func test_capabilityInvocationCompleted_error_marksCapabilityInvocationAsError() {
        // Given - start a capability
        let invocationId = "toolu_error789"
        let startResult = makeCapabilityInvocationStartResult(
            modelPrimitiveName: "execute",
            invocationId: invocationId,
            arguments: ["command": AnyCodable("invalid_command")]
        )
        viewModel.handleCapabilityInvocationStarted(startResult)

        // When - end with error
        let endResult = makeCapabilityInvocationEndResult(
            invocationId: invocationId,
            success: false,
            result: "Command not found",
            durationMs: 10
        )
        viewModel.handleCapabilityInvocationCompleted(endResult)

        // Then - capability invocation should be marked as error
        if let record = viewModel.currentTurnCapabilityInvocations.first(where: { $0.invocationId == invocationId }) {
            XCTAssertTrue(record.isError)
        }
    }

    // MARK: - Turn Lifecycle Routing Tests

    func test_turnStart_setsAgentPhaseToProcessing() {
        // Given - agent is idle
        viewModel.agentPhase = .idle

        // When
        let result = TurnStartPlugin.Result(turnNumber: 1, agentPhase: "processing")
        viewModel.handleTurnStart(result)

        // Then - should be processing (not idle)
        XCTAssertEqual(viewModel.agentPhase, .processing)
    }

    func test_turnStart_keepsProcessingActive() {
        // Given - a live cycle already marked processing
        viewModel.agentPhase = .processing

        // When
        let result = TurnStartPlugin.Result(turnNumber: 2, agentPhase: "processing")
        viewModel.handleTurnStart(result)

        // Then - should remain processing
        XCTAssertEqual(viewModel.agentPhase, .processing)
    }

    func test_fullLifecycle_processingStateTransitions() {
        // Given - simulate sendMessage sets processing
        viewModel.agentPhase = .processing

        // When - turn starts: should remain processing
        viewModel.handleTurnStart(TurnStartPlugin.Result(turnNumber: 1, agentPhase: "processing"))
        XCTAssertEqual(viewModel.agentPhase, .processing)

        // When - complete: should transition directly to idle
        viewModel.handleComplete()
        XCTAssertEqual(viewModel.agentPhase, .idle)

        // When - agent ready: should transition to idle
        viewModel.handleAgentReady()
        XCTAssertEqual(viewModel.agentPhase, .idle)
    }

    func test_turnStart_resetsCapabilityTracking() {
        // Given - have some capability invocations from previous turn
        viewModel.currentTurnCapabilityInvocations = [
            CapabilityInvocationRecord(invocationId: "old1", modelPrimitiveName: "execute", arguments: "{}")
        ]
        viewModel.currentCapabilityInvocationMessages = [UUID(): ChatMessage(role: .assistant, content: .text("test"))]

        // When
        let result = TurnStartPlugin.Result(turnNumber: 2, agentPhase: "processing")
        viewModel.handleTurnStart(result)

        // Then - capability tracking should be cleared
        XCTAssertTrue(viewModel.currentTurnCapabilityInvocations.isEmpty)
        XCTAssertTrue(viewModel.currentCapabilityInvocationMessages.isEmpty)
    }

    func test_turnStart_clearsThinkingMessageId() {
        // Given
        viewModel.thinkingMessageId = UUID()

        // When
        let result = TurnStartPlugin.Result(turnNumber: 1, agentPhase: "processing")
        viewModel.handleTurnStart(result)

        // Then
        XCTAssertNil(viewModel.thinkingMessageId)
    }

    func test_turnStartRemovesStaleCompactionSpinnerWhenNoTerminalEventArrived() {
        let spinner = ChatMessage.compactionInProgress(reason: "threshold_exceeded")
        viewModel.appendToMessages(spinner)
        viewModel.compactionInProgressMessageId = spinner.id
        viewModel.isCompacting = true

        viewModel.handleTurnStart(TurnStartPlugin.Result(turnNumber: 2, agentPhase: "processing"))

        XCTAssertFalse(viewModel.isCompacting)
        XCTAssertNil(viewModel.compactionInProgressMessageId)
        XCTAssertFalse(viewModel.messages.contains { message in
            if case .systemEvent(.compactionInProgress) = message.content {
                return true
            }
            return false
        })
    }

    func test_turnEnd_updatesContextState() {
        // Given
        let tokenRecord = makeTokenRecord(
            inputTokens: 500,
            outputTokens: 200,
            contextWindowTokens: 5000
        )
        let result = makeTurnEndResult(
            turnNumber: 1,
            tokenRecord: tokenRecord
        )

        // When
        viewModel.handleTurnEnd(result)

        // Then - context state should be updated
        XCTAssertEqual(viewModel.contextState.contextWindowTokens, 5000)
    }

    // MARK: - Complete Routing Tests

    func test_complete_setsProcessingFalse() {
        // Given
        viewModel.isProcessing = true

        // When
        viewModel.handleComplete()

        // Then
        XCTAssertFalse(viewModel.isProcessing)
    }

    func test_complete_clearsCapabilityTracking() {
        // Given: agent must be processing for handleComplete to transition
        viewModel.agentPhase = .processing
        viewModel.currentTurnCapabilityInvocations = [
            CapabilityInvocationRecord(invocationId: "t1", modelPrimitiveName: "execute", arguments: "{}")
        ]
        viewModel.currentCapabilityInvocationMessages = [UUID(): ChatMessage(role: .assistant, content: .text("test"))]

        // When
        viewModel.handleComplete()

        // Then
        XCTAssertTrue(viewModel.currentTurnCapabilityInvocations.isEmpty)
        XCTAssertTrue(viewModel.currentCapabilityInvocationMessages.isEmpty)
    }

    // MARK: - Full Turn Flow Integration Test

    func test_fullTurnFlow_startToComplete() {
        // Given - initial state
        let initialMessageCount = viewModel.messages.count
        viewModel.isProcessing = true

        // When - simulate a full turn

        // 1. Turn starts
        viewModel.handleTurnStart(TurnStartPlugin.Result(turnNumber: 1, agentPhase: "processing"))

        // 2. Agent thinks
        viewModel.handleThinkingDelta("Let me analyze this...")

        // 3. Agent responds with text
        viewModel.handleTextDelta("Here's my response: ")
        viewModel.handleTextDelta("the answer is 42.")

        // 4. Agent uses a capability
        let capabilityInvocationStartedResult = makeCapabilityInvocationStartResult(
            modelPrimitiveName: "execute",
            invocationId: "toolu_flow1",
            arguments: ["command": AnyCodable("echo test")]
        )
        viewModel.handleCapabilityInvocationStarted(capabilityInvocationStartedResult)

        let capabilityInvocationCompletedResult = makeCapabilityInvocationEndResult(
            invocationId: "toolu_flow1",
            success: true,
            result: "test\n",
            durationMs: 100
        )
        viewModel.handleCapabilityInvocationCompleted(capabilityInvocationCompletedResult)

        // 5. Turn ends
        let tokenRecord = makeTokenRecord(
            inputTokens: 100,
            outputTokens: 50,
            contextWindowTokens: 100
        )
        let turnEndResult = makeTurnEndResult(
            turnNumber: 1,
            duration: 2000,
            tokenRecord: tokenRecord
        )
        viewModel.handleTurnEnd(turnEndResult)

        // 6. Complete
        viewModel.handleComplete()

        // Then - verify final state
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertTrue(viewModel.currentTurnCapabilityInvocations.isEmpty)
        XCTAssertTrue(viewModel.currentCapabilityInvocationMessages.isEmpty)

        // Should have: thinking message + capability message = at least 2 new messages
        XCTAssertGreaterThanOrEqual(viewModel.messages.count, initialMessageCount + 2)
    }

    // MARK: - Error Handling Tests

    func test_agentError_addsErrorMessageToMessages() {
        // Given
        let initialCount = viewModel.messages.count

        // When
        viewModel.handleAgentError("Something went wrong")

        // Then - error should be appended to messages array (not set on errorMessage property)
        XCTAssertEqual(viewModel.messages.count, initialCount + 1)

        if let lastMessage = viewModel.messages.last,
           case .error(let errorText) = lastMessage.content {
            XCTAssertEqual(errorText, "Something went wrong")
        } else {
            XCTFail("Expected error message")
        }
    }

    func test_agentError_stopsProcessing() {
        // Given
        viewModel.isProcessing = true

        // When
        viewModel.handleAgentError("Error occurred")

        // Then
        XCTAssertFalse(viewModel.isProcessing)
    }

    // MARK: - Compaction Event Routing Tests

    func test_compaction_addsNotificationMessage() {
        // Given
        let initialCount = viewModel.messages.count

        // When
        let result = makeCompactionResult(
            tokensBefore: 100000,
            tokensAfter: 50000,
            reason: "context_limit",
            summary: "Summarized previous messages"
        )
        viewModel.handleCompaction(result)

        // Then - should add compaction notification
        XCTAssertEqual(viewModel.messages.count, initialCount + 1)

        if let lastMessage = viewModel.messages.last,
           case .systemEvent(let event) = lastMessage.content,
           case .compaction(let before, let after, _, _, _, _) = event {
            XCTAssertEqual(before, 100000)
            XCTAssertEqual(after, 50000)
        } else {
            XCTFail("Expected compaction notification message")
        }
    }

    func test_compaction_updatesContextState() {
        // When
        let result = makeCompactionResult(
            tokensBefore: 100000,
            tokensAfter: 50000,
            reason: "context_limit"
        )
        viewModel.handleCompaction(result)

        // Then - context state should reflect new size
        XCTAssertEqual(viewModel.contextState.lastTurnInputTokens, 50000)
    }

    // MARK: - Agent Ready (no auto-inject)

    func test_agentReady_setsIdlePhase() {
        // Given
        viewModel.agentPhase = .processing

        // When
        viewModel.handleAgentReady()

        // Then
        XCTAssertEqual(viewModel.agentPhase, .idle)
    }
}
