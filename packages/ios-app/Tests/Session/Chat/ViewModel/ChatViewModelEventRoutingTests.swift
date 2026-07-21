import XCTest
@testable import TronMobile

/// Integration tests for ChatViewModel event routing.
/// These tests verify that events flow correctly from handlers to coordinators and state.
///
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

    private func makeToolInvocationStartResult(
        toolName: String,
        invocationId: String,
        arguments: [String: AnyCodable]? = nil,
        identity: ToolIdentity? = nil
    ) -> ToolInvocationStartedPlugin.Result {
        ToolInvocationStartedPlugin.Result(
            toolName: toolName,
            invocationId: invocationId,
            arguments: arguments,
            identity: identity
        )
    }

    private func makeToolInvocationEndResult(
        invocationId: String,
        success: Bool,
        result: String?,
        durationMs: Int? = nil
    ) -> ToolInvocationCompletedPlugin.Result {
        ToolInvocationCompletedPlugin.Result(
            invocationId: invocationId,
            toolName: "test_tool",
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
        contextLimit: Int? = nil,
        model: String? = nil
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
           case .thinking(let visible, _, let isStreaming, _) = lastMessage.content {
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
           case .thinking(let visible, _, _, _) = thinkingMessage.content {
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

    func test_thinkingEnd_replacesThinkingMessageAndStopsStreaming() {
        viewModel.handleThinkingDelta("summary")

        viewModel.handleThinkingEnd("full final thinking")

        XCTAssertEqual(viewModel.thinkingState.currentText, "full final thinking")
        XCTAssertFalse(viewModel.thinkingState.isStreaming)
        guard let thinkingId = viewModel.thinkingMessageId,
              let message = viewModel.messages.first(where: { $0.id == thinkingId }),
              case .thinking(let visible, _, let isStreaming, _) = message.content else {
            return XCTFail("Expected thinking message")
        }
        XCTAssertEqual(visible, "full final thinking")
        XCTAssertFalse(isStreaming)
    }

    // MARK: - Tool Start Routing Tests

    func test_toolInvocationGenerating_createsVisibleGeneratingMessageImmediately() {
        let result = ToolInvocationGeneratingPlugin.Result(
            toolName: "process_run",
            invocationId: "toolu_generating123",
            identity: ToolIdentity(toolName: "process_run")
        )

        viewModel.handleToolInvocationGenerating(result)

        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertTrue(viewModel.animationCoordinator.isToolInvocationVisible("toolu_generating123"))
        guard case .toolInvocation(let invocation) = viewModel.messages[0].content else {
            return XCTFail("Expected tool invocation chip")
        }
        XCTAssertEqual(invocation.id, "toolu_generating123")
        XCTAssertEqual(invocation.status, .generating)
    }

    func test_parallelToolInvocationGenerating_preservesArrivalOrderBeforeCompletion() {
        viewModel.handleToolInvocationGenerating(ToolInvocationGeneratingPlugin.Result(
            toolName: "process_run",
            invocationId: "toolu_first",
            identity: ToolIdentity(toolName: "trace_list")
        ))
        viewModel.handleToolInvocationGenerating(ToolInvocationGeneratingPlugin.Result(
            toolName: "process_run",
            invocationId: "toolu_second",
            identity: ToolIdentity(toolName: "program_execution_list")
        ))

        let invocationIds = viewModel.messages.compactMap { message -> String? in
            guard case .toolInvocation(let invocation) = message.content else { return nil }
            return invocation.id
        }
        XCTAssertEqual(invocationIds, ["toolu_first", "toolu_second"])
        XCTAssertTrue(viewModel.animationCoordinator.isToolInvocationVisible("toolu_first"))
        XCTAssertTrue(viewModel.animationCoordinator.isToolInvocationVisible("toolu_second"))
    }

    func test_toolInvocationStarted_createsToolMessage() {
        // Given
        let initialCount = viewModel.messages.count
        let result = makeToolInvocationStartResult(
            toolName: "process_run",
            invocationId: "toolu_test123",
            arguments: ["command": AnyCodable("ls -la")]
        )

        // When
        viewModel.handleToolInvocationStarted(result)

        // Then - tool message should be created
        XCTAssertEqual(viewModel.messages.count, initialCount + 1)
    }

    // MARK: - Tool Progress Routing Tests

    func test_toolProgress_updatesChipProgressFields() {
        let invocationId = "toolu_progress1"
        let startResult = makeToolInvocationStartResult(
            toolName: "process_run",
            invocationId: invocationId,
            arguments: ["command": AnyCodable("long-task")]
        )
        viewModel.handleToolInvocationStarted(startResult)

        let progress = ToolInvocationProgressPlugin.Result(
            invocationId: invocationId,
            message: "downloading chunk 3/5",
            percent: 0.6
        )
        viewModel.handleToolInvocationProgress(progress)

        guard let index = viewModel.messages.lastIndex(where: {
            if case .toolInvocation(let t) = $0.content { return t.id == invocationId }
            return false
        }) else { return XCTFail("Tool invocation message not found") }

        if case .toolInvocation(let tool) = viewModel.messages[index].content {
            XCTAssertEqual(tool.progressMessage, "downloading chunk 3/5")
            XCTAssertEqual(tool.progressPercent, 0.6)
        } else {
            XCTFail("Unexpected content type")
        }
    }

    func test_toolProgress_unknownInvocationId_isIgnored() {
        let initialCount = viewModel.messages.count
        let progress = ToolInvocationProgressPlugin.Result(
            invocationId: "not-found",
            message: "ignored",
            percent: nil
        )
        viewModel.handleToolInvocationProgress(progress)
        XCTAssertEqual(viewModel.messages.count, initialCount)
    }

    func test_toolInvocationCompleted_clearsProgressFields() {
        let invocationId = "toolu_progress_end"
        viewModel.handleToolInvocationStarted(makeToolInvocationStartResult(
            toolName: "process_run",
            invocationId: invocationId,
            arguments: nil
        ))
        viewModel.handleToolInvocationProgress(ToolInvocationProgressPlugin.Result(
            invocationId: invocationId,
            message: "in-flight",
            percent: 0.4
        ))
        viewModel.handleToolInvocationCompleted(makeToolInvocationEndResult(
            invocationId: invocationId,
            success: true,
            result: "done",
            durationMs: 10
        ))
        viewModel.flushUIUpdateQueue()

        guard let index = viewModel.messages.lastIndex(where: {
            if case .toolInvocation(let t) = $0.content { return t.id == invocationId }
            return false
        }) else { return XCTFail("Tool invocation message not found") }

        if case .toolInvocation(let tool) = viewModel.messages[index].content {
            XCTAssertNil(tool.progressMessage)
            XCTAssertNil(tool.progressPercent)
        }
    }

    // MARK: - Tool Completion Routing Tests

    func test_toolInvocationCompleted_updatesToolMessage() {
        // Given - start a tool first
        let invocationId = "toolu_test456"
        let startResult = makeToolInvocationStartResult(
            toolName: "process_run",
            invocationId: invocationId,
            arguments: ["command": AnyCodable("echo hello")]
        )
        viewModel.handleToolInvocationStarted(startResult)

        // When - end the tool
        let endResult = makeToolInvocationEndResult(
            invocationId: invocationId,
            success: true,
            result: "hello\n",
            durationMs: 50
        )
        viewModel.handleToolInvocationCompleted(endResult)
        viewModel.flushUIUpdateQueue()

        guard let index = viewModel.messages.lastIndex(where: {
            if case .toolInvocation(let invocation) = $0.content { return invocation.id == invocationId }
            return false
        }) else { return XCTFail("Tool invocation message not found") }
        guard case .toolInvocation(let invocation) = viewModel.messages[index].content else {
            return XCTFail("Expected tool invocation content")
        }
        XCTAssertEqual(invocation.result, "hello\n")
        XCTAssertEqual(invocation.status, .success)
    }

    func test_toolInvocationCompleted_error_marksToolMessageAsError() {
        // Given - start a tool
        let invocationId = "toolu_error789"
        let startResult = makeToolInvocationStartResult(
            toolName: "process_run",
            invocationId: invocationId,
            arguments: ["command": AnyCodable("invalid_command")]
        )
        viewModel.handleToolInvocationStarted(startResult)

        // When - end with error
        let endResult = makeToolInvocationEndResult(
            invocationId: invocationId,
            success: false,
            result: "Command not found",
            durationMs: 10
        )
        viewModel.handleToolInvocationCompleted(endResult)
        viewModel.flushUIUpdateQueue()

        guard let index = viewModel.messages.lastIndex(where: {
            if case .toolInvocation(let invocation) = $0.content { return invocation.id == invocationId }
            return false
        }) else { return XCTFail("Tool invocation message not found") }
        guard case .toolInvocation(let invocation) = viewModel.messages[index].content else {
            return XCTFail("Expected tool invocation content")
        }
        XCTAssertEqual(invocation.status, .error)
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

    func test_streamRecoveryRequiredAdvancesReconstructionRequest() {
        let initialGeneration = viewModel.streamRecoveryRequestGeneration

        viewModel.handleStreamRecoveryRequired(
            StreamRecoveryRequiredPlugin.Result(
                reason: "source_lag",
                droppedEventCount: 3
            )
        )

        XCTAssertEqual(viewModel.streamRecoveryRequestGeneration, initialGeneration + 1)
    }

    func test_turnStart_resetsToolTracking() {
        // Given - have some tool invocations from previous turn
        viewModel.currentTurnToolMessageIds = [UUID()]

        // When
        let result = TurnStartPlugin.Result(turnNumber: 2, agentPhase: "processing")
        viewModel.handleTurnStart(result)

        // Then - tool tracking should be cleared
        XCTAssertTrue(viewModel.currentTurnToolMessageIds.isEmpty)
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
        viewModel.agentPhase = .processing

        // When
        viewModel.handleComplete()

        // Then
        XCTAssertFalse(viewModel.isProcessing)
    }

    func test_complete_clearsToolTracking() {
        // Given: agent must be processing for handleComplete to transition
        viewModel.agentPhase = .processing
        viewModel.currentTurnToolMessageIds = [UUID()]

        // When
        viewModel.handleComplete()

        // Then
        XCTAssertTrue(viewModel.currentTurnToolMessageIds.isEmpty)
    }

    // MARK: - Full Turn Flow Integration Test

    func test_fullTurnFlow_startToComplete() {
        // Given - initial state
        let initialMessageCount = viewModel.messages.count
        viewModel.agentPhase = .processing

        // When - simulate a full turn

        // 1. Turn starts
        viewModel.handleTurnStart(TurnStartPlugin.Result(turnNumber: 1, agentPhase: "processing"))

        // 2. Agent thinks
        viewModel.handleThinkingDelta("Let me analyze this...")

        // 3. Agent responds with text
        viewModel.handleTextDelta("Here's my response: ")
        viewModel.handleTextDelta("the answer is 42.")

        // 4. Agent uses a tool
        let toolInvocationStartedResult = makeToolInvocationStartResult(
            toolName: "process_run",
            invocationId: "toolu_flow1",
            arguments: ["command": AnyCodable("echo test")]
        )
        viewModel.handleToolInvocationStarted(toolInvocationStartedResult)

        let toolInvocationCompletedResult = makeToolInvocationEndResult(
            invocationId: "toolu_flow1",
            success: true,
            result: "test\n",
            durationMs: 100
        )
        viewModel.handleToolInvocationCompleted(toolInvocationCompletedResult)

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
        XCTAssertTrue(viewModel.currentTurnToolMessageIds.isEmpty)

        // Should have: thinking message + tool message = at least 2 new messages
        XCTAssertGreaterThanOrEqual(viewModel.messages.count, initialMessageCount + 2)
    }

}
