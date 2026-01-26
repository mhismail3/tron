import XCTest
@testable import TronMobile

/// Tests for ChatEventHandler event processing logic
@MainActor
final class ChatEventHandlerTests: XCTestCase {

    var handler: ChatEventHandler!
    var mockContext: MockChatEventContext!

    override func setUp() async throws {
        mockContext = MockChatEventContext()
        handler = ChatEventHandler()
    }

    override func tearDown() async throws {
        handler = nil
        mockContext = nil
    }

    // MARK: - Text Delta Tests

    func testTextDeltaHandling() async throws {
        // Given: handler and context
        mockContext.askUserQuestionCalledInTurn = false

        // When: handling a text delta
        let result = handler.handleTextDelta("Hello", context: mockContext)

        // Then: delta should be accepted
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.text, "Hello")
    }

    func testTextDeltaSuppressedWhenAskUserQuestionCalled() async throws {
        // Given: AskUserQuestion was called in this turn
        mockContext.askUserQuestionCalledInTurn = true

        // When: handling a text delta
        let result = handler.handleTextDelta("Hello", context: mockContext)

        // Then: delta should be suppressed
        XCTAssertFalse(result.accepted)
    }

    func testTextDeltaAccumulates() async throws {
        // Given: handler and context
        mockContext.askUserQuestionCalledInTurn = false

        // When: handling multiple deltas
        _ = handler.handleTextDelta("Hello", context: mockContext)
        let result = handler.handleTextDelta(" World", context: mockContext)

        // Then: text should accumulate
        XCTAssertEqual(result.text, "Hello World")
    }

    // MARK: - Thinking Delta Tests

    func testThinkingDeltaHandling() async throws {
        // When: handling thinking delta
        let result = handler.handleThinkingDelta("reasoning...")

        // Then: thinking text should be updated
        XCTAssertEqual(result.thinkingText, "reasoning...")
    }

    func testThinkingDeltaAccumulates() async throws {
        // When: handling multiple thinking deltas
        _ = handler.handleThinkingDelta("Step 1. ")
        let result = handler.handleThinkingDelta("Step 2.")

        // Then: thinking should accumulate
        XCTAssertEqual(result.thinkingText, "Step 1. Step 2.")
    }

    // MARK: - Tool Start Tests

    func testToolStartCreatesToolData() async throws {
        // Given: a tool start plugin result
        let pluginResult = ToolStartPlugin.Result(
            toolName: "Bash",
            toolCallId: "tool_123",
            arguments: nil
        )

        // When: handling tool start
        let result = handler.handleToolStart(pluginResult, context: mockContext)

        // Then: tool data should be created
        XCTAssertEqual(result.tool.toolName, "Bash")
        XCTAssertEqual(result.tool.toolCallId, "tool_123")
        XCTAssertEqual(result.tool.status, .running)
    }

    func testToolStartDetectsAskUserQuestion() async throws {
        // Given: an AskUserQuestion tool start plugin result
        let params: [String: AnyCodable] = [
            "questions": AnyCodable([
                [
                    "question": "Pick one?",
                    "header": "Test",
                    "options": [
                        ["label": "A", "description": "Option A"],
                        ["label": "B", "description": "Option B"]
                    ],
                    "multiSelect": false
                ]
            ])
        ]
        let pluginResult = ToolStartPlugin.Result(
            toolName: "AskUserQuestion",
            toolCallId: "tool_456",
            arguments: params
        )

        // When: handling tool start
        let result = handler.handleToolStart(pluginResult, context: mockContext)

        // Then: should be marked as AskUserQuestion
        XCTAssertTrue(result.isAskUserQuestion)
    }

    func testToolStartDetectsBrowserTool() async throws {
        // Given: a browser tool start plugin result
        let pluginResult = ToolStartPlugin.Result(
            toolName: "browser_snapshot",
            toolCallId: "tool_789",
            arguments: nil
        )

        // When: handling tool start
        let result = handler.handleToolStart(pluginResult, context: mockContext)

        // Then: should be marked as browser tool
        XCTAssertTrue(result.isBrowserTool)
    }

    // MARK: - Tool End Tests

    func testToolEndUpdatesStatus() async throws {
        // Given: a tool end plugin result
        let pluginResult = ToolEndPlugin.Result(
            toolCallId: "tool_123",
            toolName: "Bash",
            success: true,
            result: "Success!",
            error: nil,
            durationMs: 150,
            details: nil
        )

        // When: handling tool end
        let result = handler.handleToolEnd(pluginResult)

        // Then: status should be updated
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.result, "Success!")
        XCTAssertEqual(result.durationMs, 150)
    }

    func testToolEndWithError() async throws {
        // Given: a failed tool end plugin result
        let pluginResult = ToolEndPlugin.Result(
            toolCallId: "tool_123",
            toolName: "Bash",
            success: false,
            result: nil,
            error: "Command failed",
            durationMs: 50,
            details: nil
        )

        // When: handling tool end
        let result = handler.handleToolEnd(pluginResult)

        // Then: should be marked as error
        XCTAssertEqual(result.status, .error)
        XCTAssertEqual(result.result, "Command failed")
    }

    // MARK: - Turn Start Tests

    func testTurnStartResetsState() async throws {
        // Given: handler with accumulated state
        _ = handler.handleTextDelta("Previous text", context: mockContext)
        _ = handler.handleThinkingDelta("Previous thinking")

        // When: handling turn start
        let pluginResult = TurnStartPlugin.Result(turnNumber: 2)
        let result = handler.handleTurnStart(pluginResult)

        // Then: state should be reset
        XCTAssertEqual(result.turnNumber, 2)
        XCTAssertTrue(result.stateReset)
    }

    // MARK: - Turn End Tests

    func testTurnEndPassesThroughServerValues() async throws {
        // Given: a turn end plugin result with token usage and normalizedUsage
        let tokenUsage = TokenUsage(
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 100,
            cacheCreationTokens: 50
        )
        let normalizedUsage = NormalizedTokenUsage(
            newInputTokens: 500,
            outputTokens: 500,
            contextWindowTokens: 8500,
            rawInputTokens: 1000,
            cacheReadTokens: 8000,
            cacheCreationTokens: 50
        )
        let pluginResult = TurnEndPlugin.Result(
            turnNumber: 1,
            duration: 1500,
            tokenUsage: tokenUsage,
            normalizedUsage: normalizedUsage,
            stopReason: "end_turn",
            cost: 0.05,
            contextLimit: 200000
        )

        // When: handling turn end (no previousInputTokens parameter - uses server values)
        let result = handler.handleTurnEnd(pluginResult)

        // Then: server values should be passed through (no local calculation)
        XCTAssertEqual(result.turnNumber, 1)
        XCTAssertEqual(result.tokenUsage?.inputTokens, 1000)
        XCTAssertEqual(result.tokenUsage?.outputTokens, 500)
        XCTAssertEqual(result.normalizedUsage?.newInputTokens, 500)
        XCTAssertEqual(result.normalizedUsage?.contextWindowTokens, 8500)
        XCTAssertEqual(result.contextLimit, 200000)
        XCTAssertEqual(result.cost, 0.05)
    }

    func testTurnEndWithoutNormalizedUsage() async throws {
        // Given: a turn end plugin result without normalizedUsage (backward compatibility)
        let tokenUsage = TokenUsage(
            inputTokens: 1500,
            outputTokens: 200,
            cacheReadTokens: nil,
            cacheCreationTokens: nil
        )
        let pluginResult = TurnEndPlugin.Result(
            turnNumber: 2,
            duration: nil,
            tokenUsage: tokenUsage,
            normalizedUsage: nil,
            stopReason: "end_turn",
            cost: nil,
            contextLimit: nil
        )

        // When: handling turn end
        let result = handler.handleTurnEnd(pluginResult)

        // Then: normalizedUsage should be nil, tokenUsage should be present
        XCTAssertNil(result.normalizedUsage)
        XCTAssertEqual(result.tokenUsage?.inputTokens, 1500)
        XCTAssertEqual(result.tokenUsage?.outputTokens, 200)
    }

    func testTurnEndDoesNotRequirePreviousInputTokens() async throws {
        // Verify the method signature no longer requires previousInputTokens
        let pluginResult = TurnEndPlugin.Result(
            turnNumber: 1,
            duration: nil,
            tokenUsage: TokenUsage(inputTokens: 500, outputTokens: 100, cacheReadTokens: nil, cacheCreationTokens: nil),
            normalizedUsage: nil,
            stopReason: "end_turn",
            cost: nil,
            contextLimit: nil
        )

        // This should compile without previousInputTokens parameter
        let result = handler.handleTurnEnd(pluginResult)

        XCTAssertNotNil(result)
        XCTAssertEqual(result.turnNumber, 1)
    }

    // MARK: - Reset Tests

    func testResetClearsAllState() async throws {
        // Given: handler with accumulated state
        mockContext.askUserQuestionCalledInTurn = false
        _ = handler.handleTextDelta("Some text", context: mockContext)
        _ = handler.handleThinkingDelta("Some thinking")

        // When: resetting
        handler.reset()

        // Then: all state should be cleared
        XCTAssertEqual(handler.streamingText, "")
        XCTAssertEqual(handler.thinkingText, "")
    }

    // MARK: - Compaction Tests

    func testCompactionReturnsTokenCounts() async throws {
        // Given: a compaction plugin result
        let pluginResult = CompactionPlugin.Result(
            tokensBefore: 50000,
            tokensAfter: 25000,
            compressionRatio: 0.5,
            reason: "auto",
            summary: "Summarized context"
        )

        // When: handling compaction
        let result = handler.handleCompaction(pluginResult)

        // Then: token counts should be returned
        XCTAssertEqual(result.tokensBefore, 50000)
        XCTAssertEqual(result.tokensAfter, 25000)
        XCTAssertEqual(result.tokensSaved, 25000)
        XCTAssertEqual(result.reason, "auto")
        XCTAssertEqual(result.summary, "Summarized context")
    }

    // MARK: - Context Cleared Tests

    func testContextClearedReturnsTokenCounts() async throws {
        // Given: a context cleared plugin result
        let pluginResult = ContextClearedPlugin.Result(
            tokensBefore: 100000,
            tokensAfter: 5000
        )

        // When: handling context cleared
        let result = handler.handleContextCleared(pluginResult)

        // Then: token counts should be returned
        XCTAssertEqual(result.tokensBefore, 100000)
        XCTAssertEqual(result.tokensAfter, 5000)
        XCTAssertEqual(result.tokensFreed, 95000)
    }

    // MARK: - Message Deleted Tests

    func testMessageDeletedReturnsInfo() async throws {
        // Given: a message deleted plugin result
        let pluginResult = MessageDeletedPlugin.Result(
            targetEventId: "evt_123",
            targetType: "user",
            targetTurn: nil,
            reason: nil
        )

        // When: handling message deleted
        let result = handler.handleMessageDeleted(pluginResult)

        // Then: deletion info should be returned
        XCTAssertEqual(result.targetEventId, "evt_123")
        XCTAssertEqual(result.targetType, "user")
    }

    // MARK: - Skill Removed Tests

    func testSkillRemovedReturnsSkillName() async throws {
        // Given: a skill removed plugin result
        let pluginResult = SkillRemovedPlugin.Result(skillName: "web-search")

        // When: handling skill removed
        let result = handler.handleSkillRemoved(pluginResult)

        // Then: skill name should be returned
        XCTAssertEqual(result.skillName, "web-search")
    }

    // MARK: - Plan Mode Tests

    func testPlanModeEnteredReturnsInfo() async throws {
        // Given: a plan mode entered plugin result
        let pluginResult = PlanModeEnteredPlugin.Result(
            skillName: "architect",
            blockedTools: ["Edit", "Write"]
        )

        // When: handling plan mode entered
        let result = handler.handlePlanModeEntered(pluginResult)

        // Then: plan mode info should be returned
        XCTAssertEqual(result.skillName, "architect")
        XCTAssertEqual(result.blockedTools, ["Edit", "Write"])
    }

    func testPlanModeExitedReturnsInfo() async throws {
        // Given: a plan mode exited plugin result
        let pluginResult = PlanModeExitedPlugin.Result(
            reason: "approved",
            planPath: "/path/to/plan.md"
        )

        // When: handling plan mode exited
        let result = handler.handlePlanModeExited(pluginResult)

        // Then: exit info should be returned
        XCTAssertEqual(result.reason, "approved")
        XCTAssertEqual(result.planPath, "/path/to/plan.md")
    }

    // MARK: - Complete Tests

    func testCompleteResetsState() async throws {
        // Given: handler with accumulated state
        mockContext.askUserQuestionCalledInTurn = false
        _ = handler.handleTextDelta("Some text", context: mockContext)
        _ = handler.handleThinkingDelta("Some thinking")

        // When: handling complete
        let result = handler.handleComplete()

        // Then: state should be reset and success returned
        XCTAssertTrue(result.success)
        XCTAssertEqual(handler.streamingText, "")
        XCTAssertEqual(handler.thinkingText, "")
    }

    // MARK: - Agent Error Tests

    func testAgentErrorResetsState() async throws {
        // Given: handler with accumulated state
        mockContext.askUserQuestionCalledInTurn = false
        _ = handler.handleTextDelta("Some text", context: mockContext)
        _ = handler.handleThinkingDelta("Some thinking")

        // When: handling error
        let result = handler.handleAgentError("Something went wrong")

        // Then: state should be reset and error message returned
        XCTAssertEqual(result.message, "Something went wrong")
        XCTAssertEqual(handler.streamingText, "")
        XCTAssertEqual(handler.thinkingText, "")
    }

    // MARK: - UI Render Tests

    func testUIRenderStartReturnsCanvasInfo() async throws {
        // Given: a UI render start plugin result
        let pluginResult = UIRenderStartPlugin.Result(
            canvasId: "canvas_123",
            title: "My Canvas",
            toolCallId: "tool_456"
        )

        // When: handling UI render start
        let result = handler.handleUIRenderStart(pluginResult)

        // Then: canvas info should be returned
        XCTAssertEqual(result.canvasId, "canvas_123")
        XCTAssertEqual(result.title, "My Canvas")
        XCTAssertEqual(result.toolCallId, "tool_456")
    }

    func testUIRenderChunkReturnsChunkData() async throws {
        // Given: a UI render chunk plugin result
        let pluginResult = UIRenderChunkPlugin.Result(
            canvasId: "canvas_123",
            chunk: "{\"type\":\"text\",",
            accumulated: "{\"type\":\"text\","
        )

        // When: handling UI render chunk
        let result = handler.handleUIRenderChunk(pluginResult)

        // Then: chunk data should be returned
        XCTAssertEqual(result.canvasId, "canvas_123")
        XCTAssertEqual(result.chunk, "{\"type\":\"text\",")
        XCTAssertEqual(result.accumulated, "{\"type\":\"text\",")
    }

    func testUIRenderErrorReturnsErrorInfo() async throws {
        // Given: a UI render error plugin result
        let pluginResult = UIRenderErrorPlugin.Result(
            canvasId: "canvas_123",
            error: "Invalid JSON structure"
        )

        // When: handling UI render error
        let result = handler.handleUIRenderError(pluginResult)

        // Then: error info should be returned
        XCTAssertEqual(result.canvasId, "canvas_123")
        XCTAssertEqual(result.error, "Invalid JSON structure")
    }

    func testUIRenderRetryReturnsRetryInfo() async throws {
        // Given: a UI render retry plugin result
        let pluginResult = UIRenderRetryPlugin.Result(
            canvasId: "canvas_123",
            attempt: 2,
            errors: "Validation failed: missing required field"
        )

        // When: handling UI render retry
        let result = handler.handleUIRenderRetry(pluginResult)

        // Then: retry info should be returned
        XCTAssertEqual(result.canvasId, "canvas_123")
        XCTAssertEqual(result.attempt, 2)
        XCTAssertEqual(result.errors, "Validation failed: missing required field")
    }
}

// MARK: - Mock Context

/// Mock implementation of ChatEventContext for testing
@MainActor
final class MockChatEventContext: ChatEventContext {
    var askUserQuestionCalledInTurn: Bool = false
    var browserStatus: BrowserGetStatusResult?
    var messages: [ChatMessage] = []

    func appendMessage(_ message: ChatMessage) {
        messages.append(message)
    }

    func makeToolVisible(_ toolCallId: String) {
        // No-op for tests
    }

    func logDebug(_ message: String) {
        // No-op for tests
    }

    func logInfo(_ message: String) {
        // No-op for tests
    }

    func logWarning(_ message: String) {
        // No-op for tests
    }

    func logError(_ message: String) {
        // No-op for tests
    }
}
