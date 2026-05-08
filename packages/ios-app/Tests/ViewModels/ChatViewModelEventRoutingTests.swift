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

    private func makeToolStartResult(
        toolName: String,
        toolCallId: String,
        arguments: [String: AnyCodable]? = nil
    ) -> ToolStartPlugin.Result {
        ToolStartPlugin.Result(
            toolName: toolName,
            toolCallId: toolCallId,
            arguments: arguments
        )
    }

    private func makeToolEndResult(
        toolCallId: String,
        success: Bool,
        result: String?,
        durationMs: Int? = nil
    ) -> ToolEndPlugin.Result {
        ToolEndPlugin.Result(
            toolCallId: toolCallId,
            toolName: nil,
            success: success,
            output: result,
            error: success ? nil : result,
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
        tokensBefore: Int,
        tokensAfter: Int,
        reason: String = "context_limit",
        summary: String? = nil
    ) -> CompactionPlugin.Result {
        let ratio = tokensBefore > 0 ? Double(tokensAfter) / Double(tokensBefore) : 1.0
        return CompactionPlugin.Result(
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

    func test_textDelta_skippedWhenAskUserQuestionCalled() {
        // Given - mark AskUserQuestion as called
        viewModel.askUserQuestionCalledInTurn = true

        // When
        viewModel.handleTextDelta("Should be skipped")

        // Then - text should NOT be added
        XCTAssertEqual(viewModel.streamingManager.streamingText, "")
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

    // MARK: - Tool Start Routing Tests

    func test_toolStart_createsToolMessage() {
        // Given
        let initialCount = viewModel.messages.count
        let result = makeToolStartResult(
            toolName: "Bash",
            toolCallId: "toolu_test123",
            arguments: ["command": AnyCodable("ls -la")]
        )

        // When
        viewModel.handleToolStart(result)

        // Then - tool message should be created
        XCTAssertEqual(viewModel.messages.count, initialCount + 1)
    }

    func test_toolStart_tracksToolCall() {
        // Given
        XCTAssertTrue(viewModel.currentTurnToolCalls.isEmpty)
        let result = makeToolStartResult(
            toolName: "Read",
            toolCallId: "toolu_read123",
            arguments: ["file_path": AnyCodable("/test.txt")]
        )

        // When
        viewModel.handleToolStart(result)

        // Then - tool call should be tracked
        XCTAssertEqual(viewModel.currentTurnToolCalls.count, 1)
        XCTAssertEqual(viewModel.currentTurnToolCalls.first?.toolCallId, "toolu_read123")
        XCTAssertEqual(viewModel.currentTurnToolCalls.first?.toolName, "Read")
    }

    func test_toolStart_askUserQuestion_setsFlag() {
        // Given
        XCTAssertFalse(viewModel.askUserQuestionCalledInTurn)

        let result = makeToolStartResult(
            toolName: "AskUserQuestion",
            toolCallId: "toolu_ask123",
            arguments: [
                "questions": AnyCodable([
                    [
                        "question": "Which option?",
                        "header": "Choice",
                        "options": [
                            ["label": "A", "description": "Option A"],
                            ["label": "B", "description": "Option B"]
                        ],
                        "multiSelect": false
                    ]
                ])
            ]
        )

        // When
        viewModel.handleToolStart(result)

        // Then - flag should be set
        XCTAssertTrue(viewModel.askUserQuestionCalledInTurn)
    }

    // MARK: - Tool Progress Routing Tests

    func test_toolProgress_updatesChipProgressFields() {
        let toolCallId = "toolu_progress1"
        let startResult = makeToolStartResult(
            toolName: "Bash",
            toolCallId: toolCallId,
            arguments: ["command": AnyCodable("long-task")]
        )
        viewModel.handleToolStart(startResult)

        let progress = ToolProgressPlugin.Result(
            toolCallId: toolCallId,
            message: "downloading chunk 3/5",
            percent: 0.6
        )
        viewModel.handleToolProgress(progress)

        guard let index = viewModel.messages.lastIndex(where: {
            if case .toolUse(let t) = $0.content { return t.toolCallId == toolCallId }
            return false
        }) else { return XCTFail("Tool message not found") }

        if case .toolUse(let tool) = viewModel.messages[index].content {
            XCTAssertEqual(tool.progressMessage, "downloading chunk 3/5")
            XCTAssertEqual(tool.progressPercent, 0.6)
        } else {
            XCTFail("Unexpected content type")
        }
    }

    func test_toolProgress_unknownToolCallId_isNoop() {
        let initialCount = viewModel.messages.count
        let progress = ToolProgressPlugin.Result(
            toolCallId: "not-found",
            message: "ignored",
            percent: nil
        )
        viewModel.handleToolProgress(progress)
        XCTAssertEqual(viewModel.messages.count, initialCount)
    }

    func test_toolEnd_clearsProgressFields() {
        let toolCallId = "toolu_progress_end"
        viewModel.handleToolStart(makeToolStartResult(
            toolName: "Bash",
            toolCallId: toolCallId,
            arguments: nil
        ))
        viewModel.handleToolProgress(ToolProgressPlugin.Result(
            toolCallId: toolCallId,
            message: "in-flight",
            percent: 0.4
        ))
        viewModel.handleToolEnd(makeToolEndResult(
            toolCallId: toolCallId,
            success: true,
            result: "done",
            durationMs: 10
        ))
        viewModel.flushUIUpdateQueue()

        guard let index = viewModel.messages.lastIndex(where: {
            if case .toolUse(let t) = $0.content { return t.toolCallId == toolCallId }
            return false
        }) else { return XCTFail("Tool message not found") }

        if case .toolUse(let tool) = viewModel.messages[index].content {
            XCTAssertNil(tool.progressMessage)
            XCTAssertNil(tool.progressPercent)
        }
    }

    // MARK: - Tool End Routing Tests

    func test_toolEnd_updatesTrackedToolCall() {
        // Given - start a tool first
        let toolCallId = "toolu_test456"
        let startResult = makeToolStartResult(
            toolName: "Bash",
            toolCallId: toolCallId,
            arguments: ["command": AnyCodable("echo hello")]
        )
        viewModel.handleToolStart(startResult)

        // When - end the tool
        let endResult = makeToolEndResult(
            toolCallId: toolCallId,
            success: true,
            result: "hello\n",
            durationMs: 50
        )
        viewModel.handleToolEnd(endResult)

        // Then - tracked tool call should have result
        if let record = viewModel.currentTurnToolCalls.first(where: { $0.toolCallId == toolCallId }) {
            XCTAssertEqual(record.result, "hello\n")
            XCTAssertFalse(record.isError)
        } else {
            XCTFail("Tool call record not found")
        }
    }

    func test_toolEnd_error_marksToolCallAsError() {
        // Given - start a tool
        let toolCallId = "toolu_error789"
        let startResult = makeToolStartResult(
            toolName: "Bash",
            toolCallId: toolCallId,
            arguments: ["command": AnyCodable("invalid_command")]
        )
        viewModel.handleToolStart(startResult)

        // When - end with error
        let endResult = makeToolEndResult(
            toolCallId: toolCallId,
            success: false,
            result: "Command not found",
            durationMs: 10
        )
        viewModel.handleToolEnd(endResult)

        // Then - tool call should be marked as error
        if let record = viewModel.currentTurnToolCalls.first(where: { $0.toolCallId == toolCallId }) {
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

    func test_turnStart_restoresProcessingFromStalePostProcessing() {
        // Given - stale postProcessing from a previous cycle that never got agent_ready
        viewModel.agentPhase = .postProcessing

        // When
        let result = TurnStartPlugin.Result(turnNumber: 2, agentPhase: "processing")
        viewModel.handleTurnStart(result)

        // Then - should clear stale postProcessing and set to processing
        XCTAssertEqual(viewModel.agentPhase, .processing)
    }

    func test_fullLifecycle_processingStateTransitions() {
        // Given - simulate sendMessage sets processing
        viewModel.agentPhase = .processing

        // When - turn starts: should remain processing
        viewModel.handleTurnStart(TurnStartPlugin.Result(turnNumber: 1, agentPhase: "processing"))
        XCTAssertEqual(viewModel.agentPhase, .processing)

        // When - complete: should transition to postProcessing
        viewModel.handleComplete()
        XCTAssertEqual(viewModel.agentPhase, .postProcessing)

        // When - agent ready: should transition to idle
        viewModel.handleAgentReady()
        XCTAssertEqual(viewModel.agentPhase, .idle)
    }

    func test_turnStart_resetsToolTracking() {
        // Given - have some tool calls from previous turn
        viewModel.currentTurnToolCalls = [
            ToolCallRecord(toolCallId: "old1", toolName: "Bash", arguments: "{}")
        ]
        viewModel.currentToolMessages = [UUID(): ChatMessage(role: .assistant, content: .text("test"))]

        // When
        let result = TurnStartPlugin.Result(turnNumber: 2, agentPhase: "processing")
        viewModel.handleTurnStart(result)

        // Then - tool tracking should be cleared
        XCTAssertTrue(viewModel.currentTurnToolCalls.isEmpty)
        XCTAssertTrue(viewModel.currentToolMessages.isEmpty)
    }

    func test_turnStart_resetsAskUserQuestionFlag() {
        // Given
        viewModel.askUserQuestionCalledInTurn = true

        // When
        let result = TurnStartPlugin.Result(turnNumber: 1, agentPhase: "processing")
        viewModel.handleTurnStart(result)

        // Then
        XCTAssertFalse(viewModel.askUserQuestionCalledInTurn)
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

    func test_complete_clearsToolTracking() {
        // Given: agent must be processing for handleComplete to transition
        viewModel.agentPhase = .processing
        viewModel.currentTurnToolCalls = [
            ToolCallRecord(toolCallId: "t1", toolName: "Bash", arguments: "{}")
        ]
        viewModel.currentToolMessages = [UUID(): ChatMessage(role: .assistant, content: .text("test"))]

        // When
        viewModel.handleComplete()

        // Then
        XCTAssertTrue(viewModel.currentTurnToolCalls.isEmpty)
        XCTAssertTrue(viewModel.currentToolMessages.isEmpty)
    }

    // MARK: - Subagent Routing Tests

    func test_subagentSpawned_updatesSubagentState() {
        // Given
        XCTAssertTrue(viewModel.subagentState.subagents.isEmpty)

        // When
        let result = SubagentSpawnedPlugin.Result(
            subagentSessionId: "sub_123",
            task: "Exploring codebase",
            model: "claude-3-sonnet",
            workingDirectory: "/test/dir",
            toolCallId: "toolu_spawn1",
            blocking: false,
            spawnType: nil
        )
        viewModel.handleSubagentSpawnedResult(result)

        // Then - subagent should be tracked
        XCTAssertFalse(viewModel.subagentState.subagents.isEmpty)
        XCTAssertNotNil(viewModel.subagentState.subagents["sub_123"])
    }

    func test_subagentCompleted_updatesState() {
        // Given - spawn a subagent first
        let spawnedResult = SubagentSpawnedPlugin.Result(
            subagentSessionId: "sub_complete",
            task: "Planning",
            model: "claude-3-opus",
            workingDirectory: nil,
            toolCallId: "toolu_spawn2",
            blocking: false,
            spawnType: nil
        )
        viewModel.handleSubagentSpawnedResult(spawnedResult)

        // When - subagent completes
        let completedResult = SubagentCompletedPlugin.Result(
            subagentSessionId: "sub_complete",
            resultSummary: "Plan complete",
            fullOutput: "Full output text here",
            totalTurns: 5,
            duration: 10000,
            tokenUsage: nil,
            model: nil
        )
        viewModel.handleSubagentCompletedResult(completedResult)

        // Then - subagent should be marked as complete
        if let subagent = viewModel.subagentState.subagents["sub_complete"] {
            XCTAssertEqual(subagent.status, .completed)
        }
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

        // 4. Agent uses a tool
        let toolStartResult = makeToolStartResult(
            toolName: "Bash",
            toolCallId: "toolu_flow1",
            arguments: ["command": AnyCodable("echo test")]
        )
        viewModel.handleToolStart(toolStartResult)

        let toolEndResult = makeToolEndResult(
            toolCallId: "toolu_flow1",
            success: true,
            result: "test\n",
            durationMs: 100
        )
        viewModel.handleToolEnd(toolEndResult)

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
        XCTAssertTrue(viewModel.currentTurnToolCalls.isEmpty)
        XCTAssertTrue(viewModel.currentToolMessages.isEmpty)

        // Should have: thinking message + tool message = at least 2 new messages
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

    // MARK: - Subagent Result Available Gating Tests

    private func spawnNonBlockingSubagent(sessionId: String = "sub-nb", task: String = "Background task") {
        let result = SubagentSpawnedPlugin.Result(
            subagentSessionId: sessionId,
            task: task,
            model: "claude-sonnet-4-6",
            workingDirectory: nil,
            toolCallId: "tc-\(sessionId)",
            blocking: false,
            spawnType: nil
        )
        viewModel.handleSubagentSpawnedResult(result)
        // Mark as completed so deliverSubagentResults() will accept it
        viewModel.subagentState.complete(
            subagentSessionId: sessionId,
            resultSummary: "Done",
            fullOutput: "Full output",
            totalTurns: 2,
            duration: 500,
            tokenUsage: nil
        )
    }

    private func makeResultAvailable(
        sessionId: String = "sub-nb",
        notify: Bool = true
    ) -> SubagentResultAvailablePlugin.Result {
        SubagentResultAvailablePlugin.Result(
            parentSessionId: "test-session",
            subagentSessionId: sessionId,
            task: "Background task",
            resultSummary: "Done",
            success: true,
            totalTurns: 2,
            duration: 500,
            tokenUsage: nil,
            error: nil,
            completedAt: "2026-01-01T00:00:00Z",
            notify: notify
        )
    }

    func test_subagentResultAvailable_notifyFalse_skipsNotification() {
        // Given — server decided no notification (parent is actively running)
        spawnNonBlockingSubagent()
        let initialCount = viewModel.messages.count

        // When
        viewModel.handleSubagentResultAvailableResult(makeResultAvailable(notify: false))

        // Then — no notification, status unchanged (backend delivers results)
        XCTAssertEqual(viewModel.messages.count, initialCount)
        XCTAssertEqual(viewModel.subagentState.subagents["sub-nb"]?.resultDeliveryStatus, .notApplicable)
    }

    func test_subagentResultAvailable_notifyTrue_showsNotification() {
        // Given — server decided to notify (parent is idle)
        spawnNonBlockingSubagent()
        let initialCount = viewModel.messages.count

        // When
        viewModel.handleSubagentResultAvailableResult(makeResultAvailable(notify: true))

        // Then — notification message added, status is pending
        XCTAssertEqual(viewModel.subagentState.subagents["sub-nb"]?.resultDeliveryStatus, .pending)
        XCTAssertGreaterThan(viewModel.messages.count, initialCount)
    }

    func test_subagentResultAvailable_notifyIgnoresAgentPhase() {
        // Regression test: iOS no longer makes routing decisions based on
        // agentPhase. The server-provided `notify` field is authoritative,
        // even if the local agentPhase has drifted (e.g., during rapid
        // transitions or reconstruction races).
        spawnNonBlockingSubagent()
        viewModel.agentPhase = .processing // would have suppressed under old logic
        let initialCount = viewModel.messages.count

        viewModel.handleSubagentResultAvailableResult(makeResultAvailable(notify: true))

        // Server said notify=true — we show the notification regardless of phase.
        XCTAssertGreaterThan(viewModel.messages.count, initialCount)
        XCTAssertEqual(viewModel.subagentState.subagents["sub-nb"]?.resultDeliveryStatus, .pending)
    }

    func test_subagentResultAvailable_consolidatesMultipleNotifyTrue() {
        // Given — two non-blocking subagents spawn
        spawnNonBlockingSubagent(sessionId: "sub-nb")
        spawnNonBlockingSubagent(sessionId: "sub-nb2")
        let initialCount = viewModel.messages.count

        // When — both complete with notify=true
        viewModel.handleSubagentResultAvailableResult(makeResultAvailable(sessionId: "sub-nb", notify: true))
        viewModel.handleSubagentResultAvailableResult(makeResultAvailable(sessionId: "sub-nb2", notify: true))

        // Then — single consolidated notification message with both entries
        let resultsReadyCount = viewModel.messages.filter { msg in
            if case .systemEvent(.subagentResultsReady) = msg.content { return true }
            return false
        }.count
        XCTAssertEqual(resultsReadyCount, 1, "expected one consolidated notification")
        XCTAssertEqual(viewModel.messages.count, initialCount + 1)
    }

    // MARK: - Agent Ready (no auto-inject)

    func test_agentReady_setsIdlePhase() {
        // Given
        viewModel.agentPhase = .postProcessing

        // When
        viewModel.handleAgentReady()

        // Then
        XCTAssertEqual(viewModel.agentPhase, .idle)
    }
}
