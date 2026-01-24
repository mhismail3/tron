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
        // Given: a tool start event
        let event = ToolStartEvent(
            toolName: "Bash",
            toolCallId: "tool_123",
            arguments: nil,
            formattedArguments: "{\"command\": \"ls -la\"}"
        )

        // When: handling tool start
        let result = handler.handleToolStart(event, context: mockContext)

        // Then: tool data should be created
        XCTAssertEqual(result.tool.toolName, "Bash")
        XCTAssertEqual(result.tool.toolCallId, "tool_123")
        XCTAssertEqual(result.tool.status, .running)
    }

    func testToolStartDetectsAskUserQuestion() async throws {
        // Given: an AskUserQuestion tool start
        let params = """
        {"questions":[{"question":"Pick one?","header":"Test","options":[{"label":"A","description":"Option A"},{"label":"B","description":"Option B"}],"multiSelect":false}]}
        """
        let event = ToolStartEvent(
            toolName: "AskUserQuestion",
            toolCallId: "tool_456",
            arguments: nil,
            formattedArguments: params
        )

        // When: handling tool start
        let result = handler.handleToolStart(event, context: mockContext)

        // Then: should be marked as AskUserQuestion
        XCTAssertTrue(result.isAskUserQuestion)
    }

    func testToolStartDetectsBrowserTool() async throws {
        // Given: a browser tool start
        let event = ToolStartEvent(
            toolName: "browser_snapshot",
            toolCallId: "tool_789",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: handling tool start
        let result = handler.handleToolStart(event, context: mockContext)

        // Then: should be marked as browser tool
        XCTAssertTrue(result.isBrowserTool)
    }

    // MARK: - Tool End Tests

    func testToolEndUpdatesStatus() async throws {
        // Given: a tool end event
        let event = ToolEndEvent(
            toolCallId: "tool_123",
            success: true,
            displayResult: "Success!",
            durationMs: 150,
            details: nil
        )

        // When: handling tool end
        let result = handler.handleToolEnd(event)

        // Then: status should be updated
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.result, "Success!")
        XCTAssertEqual(result.durationMs, 150)
    }

    func testToolEndWithError() async throws {
        // Given: a failed tool end event
        let event = ToolEndEvent(
            toolCallId: "tool_123",
            success: false,
            displayResult: "Command failed",
            durationMs: 50,
            details: nil
        )

        // When: handling tool end
        let result = handler.handleToolEnd(event)

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
        let event = TurnStartEvent(turnNumber: 2)
        let result = handler.handleTurnStart(event)

        // Then: state should be reset
        XCTAssertEqual(result.turnNumber, 2)
        XCTAssertTrue(result.stateReset)
    }

    // MARK: - Turn End Tests

    func testTurnEndPassesThroughServerValues() async throws {
        // Given: a turn end event with token usage and normalizedUsage
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
        let turnData = TurnEndData(
            turnNumber: 1,
            duration: 1500
        )
        let event = TurnEndEvent(
            turnNumber: 1,
            stopReason: "end_turn",
            tokenUsage: tokenUsage,
            normalizedUsage: normalizedUsage,
            contextLimit: 200000,
            data: turnData,
            cost: 0.05
        )

        // When: handling turn end (no previousInputTokens parameter - uses server values)
        let result = handler.handleTurnEnd(event)

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
        // Given: a turn end event without normalizedUsage (backward compatibility)
        let tokenUsage = TokenUsage(
            inputTokens: 1500,
            outputTokens: 200,
            cacheReadTokens: nil,
            cacheCreationTokens: nil
        )
        let event = TurnEndEvent(
            turnNumber: 2,
            stopReason: "end_turn",
            tokenUsage: tokenUsage,
            normalizedUsage: nil,
            contextLimit: nil,
            data: nil,
            cost: nil
        )

        // When: handling turn end
        let result = handler.handleTurnEnd(event)

        // Then: normalizedUsage should be nil, tokenUsage should be present
        XCTAssertNil(result.normalizedUsage)
        XCTAssertEqual(result.tokenUsage?.inputTokens, 1500)
        XCTAssertEqual(result.tokenUsage?.outputTokens, 200)
    }

    func testTurnEndDoesNotRequirePreviousInputTokens() async throws {
        // Verify the method signature no longer requires previousInputTokens
        let event = TurnEndEvent(
            turnNumber: 1,
            stopReason: "end_turn",
            tokenUsage: TokenUsage(inputTokens: 500, outputTokens: 100, cacheReadTokens: nil, cacheCreationTokens: nil),
            normalizedUsage: nil,
            contextLimit: nil,
            data: nil,
            cost: nil
        )

        // This should compile without previousInputTokens parameter
        let result = handler.handleTurnEnd(event)

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
