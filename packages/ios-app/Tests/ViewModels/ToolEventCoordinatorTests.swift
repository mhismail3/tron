import XCTest
@testable import TronMobile

/// Tests for ToolEventCoordinator - handles tool start/end UI coordination
/// Uses TDD: Tests written first, then implementation follows
@MainActor
final class ToolEventCoordinatorTests: XCTestCase {

    var coordinator: ToolEventCoordinator!
    var mockContext: MockToolEventContext!

    override func setUp() async throws {
        mockContext = MockToolEventContext()
        coordinator = ToolEventCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - Tool Generating Tests

    func testToolGeneratingCreatesRunningChip() async throws {
        // Given: A tool generating event
        let result = ToolGeneratingPlugin.Result(toolName: "Write", toolCallId: "gen_123")

        // When: Handling tool generating
        coordinator.handleToolGenerating(result, context: mockContext)

        // Then: A tool message should be created with .running status
        XCTAssertEqual(mockContext.messages.count, 1)
        XCTAssertEqual(mockContext.messages[0].role, .assistant)
        if case .toolUse(let tool) = mockContext.messages[0].content {
            XCTAssertEqual(tool.toolName, "Write")
            XCTAssertEqual(tool.toolCallId, "gen_123")
            XCTAssertEqual(tool.status, .running)
            XCTAssertEqual(tool.arguments, "")
        } else {
            XCTFail("Expected toolUse content")
        }
    }

    func testToolGeneratingFinalizesThinkingMessage() async throws {
        let result = ToolGeneratingPlugin.Result(toolName: "Write", toolCallId: "gen_think")

        coordinator.handleToolGenerating(result, context: mockContext)

        XCTAssertTrue(mockContext.finalizeThinkingMessageIfNeededCalled)
    }

    func testToolGeneratingFlushesStreamingText() async throws {
        let result = ToolGeneratingPlugin.Result(toolName: "Write", toolCallId: "gen_flush")

        coordinator.handleToolGenerating(result, context: mockContext)

        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testToolGeneratingMakesToolVisible() async throws {
        let result = ToolGeneratingPlugin.Result(toolName: "Write", toolCallId: "gen_vis")

        coordinator.handleToolGenerating(result, context: mockContext)

        XCTAssertTrue(mockContext.visibleToolCallIds.contains("gen_vis"))
    }

    func testToolGeneratingEnqueuesToolStart() async throws {
        let result = ToolGeneratingPlugin.Result(toolName: "Write", toolCallId: "gen_enq")

        coordinator.handleToolGenerating(result, context: mockContext)

        XCTAssertEqual(mockContext.enqueuedToolStarts.count, 1)
        XCTAssertEqual(mockContext.enqueuedToolStarts[0].toolCallId, "gen_enq")
        XCTAssertEqual(mockContext.enqueuedToolStarts[0].toolName, "Write")
    }

    func testToolGeneratingTracksToolCall() async throws {
        let result = ToolGeneratingPlugin.Result(toolName: "Bash", toolCallId: "gen_track")

        coordinator.handleToolGenerating(result, context: mockContext)

        XCTAssertEqual(mockContext.currentTurnToolCalls.count, 1)
        XCTAssertEqual(mockContext.currentTurnToolCalls[0].toolCallId, "gen_track")
        XCTAssertEqual(mockContext.currentTurnToolCalls[0].toolName, "Bash")
    }

    func testToolGeneratingSkipsDuplicateChip() async throws {
        // Given: A tool message already exists
        let existing = ChatMessage(
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: "Write",
                toolCallId: "dup_123",
                arguments: "{}",
                status: .running
            ))
        )
        mockContext.messages.append(existing)

        // When: tool_generating arrives for same toolCallId
        let result = ToolGeneratingPlugin.Result(toolName: "Write", toolCallId: "dup_123")
        coordinator.handleToolGenerating(result, context: mockContext)

        // Then: No duplicate message created
        XCTAssertEqual(mockContext.messages.count, 1)
    }

    func testToolGeneratingCreatesGeneratingChipForAskUserQuestion() async throws {
        let result = ToolGeneratingPlugin.Result(toolName: "AskUserQuestion", toolCallId: "gen_ask")

        coordinator.handleToolGenerating(result, context: mockContext)

        // Should create a message with .generating status
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .askUserQuestion(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.toolCallId, "gen_ask")
            XCTAssertEqual(data.status, .generating)
            XCTAssertTrue(data.params.questions.isEmpty)
        } else {
            XCTFail("Expected askUserQuestion content")
        }
        XCTAssertTrue(mockContext.visibleToolCallIds.contains("gen_ask"))
    }

    func testToolStartUpdatesGeneratingAskUserQuestionChip() async throws {
        // Given: tool_generating already created a .generating chip
        let genResult = ToolGeneratingPlugin.Result(toolName: "AskUserQuestion", toolCallId: "gen_ask_update")
        coordinator.handleToolGenerating(genResult, context: mockContext)
        XCTAssertEqual(mockContext.messages.count, 1)

        // When: tool_start arrives with real params encoded in formattedArguments
        let params = AskUserQuestionParams(
            questions: [
                AskUserQuestion(
                    id: "q1",
                    question: "Pick one?",
                    options: [
                        AskUserQuestionOption(label: "A", value: nil, description: nil),
                        AskUserQuestionOption(label: "B", value: nil, description: nil)
                    ],
                    mode: .single,
                    allowOther: false,
                    otherPlaceholder: nil
                )
            ],
            context: nil
        )
        let paramsJson = String(data: try! JSONEncoder().encode(params), encoding: .utf8)!
        let event = ToolStartPlugin.Result(
            toolName: "AskUserQuestion",
            toolCallId: "gen_ask_update",
            arguments: nil,
            formattedArguments: paramsJson
        )
        coordinator.handleToolStart(event, context: mockContext)

        // Then: No duplicate message (still just 1)
        XCTAssertEqual(mockContext.messages.count, 1)
        // Then: Status updated from .generating to .pending with real params
        if case .askUserQuestion(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.status, .pending)
            XCTAssertEqual(data.params.questions.count, 1)
            XCTAssertEqual(data.params.questions[0].question, "Pick one?")
        } else {
            XCTFail("Expected askUserQuestion content")
        }
        // Then: calledInTurn is set
        XCTAssertTrue(mockContext.askUserQuestionCalledInTurn)
    }

    func testToolStartUpdatesDuplicateFromGenerating() async throws {
        // Given: tool_generating already created a chip with empty arguments
        let genResult = ToolGeneratingPlugin.Result(toolName: "Write", toolCallId: "gen_first")
        coordinator.handleToolGenerating(genResult, context: mockContext)
        XCTAssertEqual(mockContext.messages.count, 1)

        // When: tool_start arrives for same toolCallId with full arguments
        let event = ToolStartPlugin.Result(
            toolName: "Write",
            toolCallId: "gen_first",
            arguments: ["file_path": AnyCodable("/test.txt")],
            formattedArguments: "{\"file_path\":\"/test.txt\"}"
        )
        coordinator.handleToolStart(event, context: mockContext)

        // Then: No duplicate message (still just 1)
        XCTAssertEqual(mockContext.messages.count, 1)
        // Then: Tool is still visible
        XCTAssertTrue(mockContext.visibleToolCallIds.contains("gen_first"))
        // Then: Arguments are updated from empty to full
        if case .toolUse(let tool) = mockContext.messages[0].content {
            XCTAssertFalse(tool.arguments.isEmpty, "Arguments should be updated from empty")
            XCTAssertTrue(tool.arguments.contains("file_path"), "Arguments should contain the file_path")
        } else {
            XCTFail("Expected toolUse content")
        }
        // Then: currentToolMessages is updated
        XCTAssertEqual(mockContext.currentToolMessages.count, 1)
        // Then: currentTurnToolCalls arguments are updated
        XCTAssertTrue(mockContext.currentTurnToolCalls[0].arguments.contains("file_path"))
    }

    func testToolEndUpdatesGeneratingChip() async throws {
        // Given: tool_generating created a chip
        let genResult = ToolGeneratingPlugin.Result(toolName: "Write", toolCallId: "gen_end")
        coordinator.handleToolGenerating(genResult, context: mockContext)
        XCTAssertEqual(mockContext.currentTurnToolCalls.count, 1)

        // When: tool_end arrives
        let endEvent = ToolEndPlugin.Result(
            toolCallId: "gen_end",
            success: true,
            displayResult: "File written",
            durationMs: 150,
            details: nil
        )
        coordinator.handleToolEnd(endEvent, context: mockContext)

        // Then: Tool call record is updated
        XCTAssertEqual(mockContext.currentTurnToolCalls[0].result, "File written")
        // Then: Tool end is enqueued
        XCTAssertEqual(mockContext.enqueuedToolEnds.count, 1)
    }

    func testMultipleToolGeneratingEvents() async throws {
        // When: Two tool_generating events arrive
        coordinator.handleToolGenerating(
            ToolGeneratingPlugin.Result(toolName: "Write", toolCallId: "tc1"),
            context: mockContext
        )
        coordinator.handleToolGenerating(
            ToolGeneratingPlugin.Result(toolName: "Bash", toolCallId: "tc2"),
            context: mockContext
        )

        // Then: Two messages created
        XCTAssertEqual(mockContext.messages.count, 2)
        // Then: Both have .running status
        if case .toolUse(let tool1) = mockContext.messages[0].content {
            XCTAssertEqual(tool1.status, .running)
            XCTAssertEqual(tool1.toolName, "Write")
        } else { XCTFail("Expected toolUse content") }
        if case .toolUse(let tool2) = mockContext.messages[1].content {
            XCTAssertEqual(tool2.status, .running)
            XCTAssertEqual(tool2.toolName, "Bash")
        } else { XCTFail("Expected toolUse content") }
        // Then: Two enqueued tool starts
        XCTAssertEqual(mockContext.enqueuedToolStarts.count, 2)
        XCTAssertEqual(mockContext.enqueuedToolStarts[0].toolCallId, "tc1")
        XCTAssertEqual(mockContext.enqueuedToolStarts[1].toolCallId, "tc2")
    }

    // MARK: - Tool Start Tests

    func testToolStartCreatesToolMessage() async throws {
        // Given: A tool start event
        let event = ToolStartPlugin.Result(
            toolName: "Bash",
            toolCallId: "tool_123",
            arguments: nil,
            formattedArguments: "{\"command\": \"ls -la\"}"
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, context: mockContext)

        // Then: A tool message should be created
        XCTAssertEqual(mockContext.messages.count, 1)
        XCTAssertEqual(mockContext.messages[0].role, .assistant)
        if case .toolUse(let tool) = mockContext.messages[0].content {
            XCTAssertEqual(tool.toolName, "Bash")
            XCTAssertEqual(tool.toolCallId, "tool_123")
            XCTAssertEqual(tool.status, .running)
        } else {
            XCTFail("Expected toolUse content")
        }
    }

    func testToolStartFlushesStreamingTextFirst() async throws {
        // Given: A tool start event
        let event = ToolStartPlugin.Result(
            toolName: "Read",
            toolCallId: "tool_456",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, context: mockContext)

        // Then: Streaming text should be flushed first
        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testToolStartFinalizesThinkingMessage() async throws {
        // Given: A tool start event
        let event = ToolStartPlugin.Result(
            toolName: "Read",
            toolCallId: "tool_thinking_start",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, context: mockContext)

        // Then: Thinking should be finalized
        XCTAssertTrue(mockContext.finalizeThinkingMessageIfNeededCalled)
    }

    func testToolStartTracksToolCall() async throws {
        // Given: A tool start event
        let event = ToolStartPlugin.Result(
            toolName: "Grep",
            toolCallId: "tool_789",
            arguments: nil,
            formattedArguments: "{\"pattern\": \"TODO\"}"
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, context: mockContext)

        // Then: Tool call should be tracked
        XCTAssertEqual(mockContext.currentTurnToolCalls.count, 1)
        XCTAssertEqual(mockContext.currentTurnToolCalls[0].toolCallId, "tool_789")
        XCTAssertEqual(mockContext.currentTurnToolCalls[0].toolName, "Grep")
    }

    func testToolStartMakesToolVisible() async throws {
        // Given: A tool start event
        let event = ToolStartPlugin.Result(
            toolName: "Edit",
            toolCallId: "tool_visible",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, context: mockContext)

        // Then: Tool should be made visible for animation
        XCTAssertTrue(mockContext.visibleToolCallIds.contains("tool_visible"))
    }

    func testToolStartEnqueuesForUIUpdateQueue() async throws {
        // Given: A tool start event
        let event = ToolStartPlugin.Result(
            toolName: "Write",
            toolCallId: "tool_queue",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, context: mockContext)

        // Then: Should be enqueued for ordered processing
        XCTAssertEqual(mockContext.enqueuedToolStarts.count, 1)
        XCTAssertEqual(mockContext.enqueuedToolStarts[0].toolCallId, "tool_queue")
    }

    // MARK: - AskUserQuestion Tool Tests

    func testAskUserQuestionToolStart() async throws {
        // Given: An AskUserQuestion tool start with params encoded in formattedArguments
        let params = AskUserQuestionParams(
            questions: [
                AskUserQuestion(
                    id: "q1",
                    question: "Pick one?",
                    options: [
                        AskUserQuestionOption(label: "A", value: nil, description: "Option A"),
                        AskUserQuestionOption(label: "B", value: nil, description: "Option B")
                    ],
                    mode: .single,
                    allowOther: false,
                    otherPlaceholder: nil
                )
            ],
            context: nil
        )
        let paramsJson = String(data: try! JSONEncoder().encode(params), encoding: .utf8)!
        let event = ToolStartPlugin.Result(
            toolName: "AskUserQuestion",
            toolCallId: "ask_123",
            arguments: nil,
            formattedArguments: paramsJson
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, context: mockContext)

        // Then: Should create AskUserQuestion message
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .askUserQuestion(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.toolCallId, "ask_123")
            XCTAssertEqual(data.status, .pending)
            XCTAssertEqual(data.params.questions.count, 1)
        } else {
            XCTFail("Expected askUserQuestion content")
        }

        // Then: Should mark calledInTurn
        XCTAssertTrue(mockContext.askUserQuestionCalledInTurn)
    }

    func testAskUserQuestionToolStartFallsBackOnParseFailure() async throws {
        // Given: An AskUserQuestion tool start with invalid JSON (parse will fail)
        let event = ToolStartPlugin.Result(
            toolName: "AskUserQuestion",
            toolCallId: "ask_fail",
            arguments: nil,
            formattedArguments: "invalid json"
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, context: mockContext)

        // Then: Should fall back to regular tool display
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .toolUse(let tool) = mockContext.messages[0].content {
            XCTAssertEqual(tool.toolName, "AskUserQuestion")
        } else {
            XCTFail("Expected toolUse content for fallback")
        }
    }

    // MARK: - Tool End Tests

    func testToolEndEnqueuesForProcessing() async throws {
        // Given: A tool end event
        let event = ToolEndPlugin.Result(
            toolCallId: "tool_end_123",
            success: true,
            displayResult: "Success!",
            durationMs: 150,
            details: nil
        )

        // When: Handling tool end
        coordinator.handleToolEnd(event, context: mockContext)

        // Then: Should enqueue for ordered processing
        XCTAssertEqual(mockContext.enqueuedToolEnds.count, 1)
        XCTAssertEqual(mockContext.enqueuedToolEnds[0].toolCallId, "tool_end_123")
        XCTAssertTrue(mockContext.enqueuedToolEnds[0].success)
    }

    func testToolEndUpdatesToolCallRecord() async throws {
        // Given: A tracked tool call
        mockContext.currentTurnToolCalls.append(ToolCallRecord(
            toolCallId: "tool_track_123",
            toolName: "Bash",
            arguments: "{}"
        ))

        // Given: A tool end event
        let event = ToolEndPlugin.Result(
            toolCallId: "tool_track_123",
            success: false,
            displayResult: "Command failed",
            durationMs: 50,
            details: nil
        )

        // When: Handling tool end
        coordinator.handleToolEnd(event, context: mockContext)

        // Then: Tool call record should be updated
        XCTAssertEqual(mockContext.currentTurnToolCalls[0].result, "Command failed")
        XCTAssertTrue(mockContext.currentTurnToolCalls[0].isError ?? false)
    }

    func testAskUserQuestionToolEndOpensSheet() async throws {
        // Given: An AskUserQuestion message exists
        let askData = AskUserQuestionToolData(
            toolCallId: "ask_sheet_123",
            params: AskUserQuestionParams(
                questions: [
                    AskUserQuestion(
                        id: "q1",
                        question: "Pick?",
                        options: [
                            AskUserQuestionOption(label: "A", value: nil, description: nil)
                        ],
                        mode: .single,
                        allowOther: false,
                        otherPlaceholder: nil
                    )
                ],
                context: nil
            ),
            answers: [:],
            status: .pending,
            result: nil
        )
        mockContext.messages.append(ChatMessage(
            role: .assistant,
            content: .askUserQuestion(askData)
        ))

        // Given: Tool end arrives
        let event = ToolEndPlugin.Result(
            toolCallId: "ask_sheet_123",
            success: true,
            displayResult: "",
            durationMs: 100,
            details: nil
        )

        // When: Handling tool end
        coordinator.handleToolEnd(event, context: mockContext)

        // Then: Sheet should be opened
        XCTAssertTrue(mockContext.askUserQuestionSheetOpened)
    }

    // MARK: - Thinking Block Boundary Tests

    func testToolEndResetsThinkingStateForNewBlock() async throws {
        // Given: A tool end event
        let event = ToolEndPlugin.Result(
            toolCallId: "tool_thinking_reset",
            success: true,
            displayResult: "Done",
            durationMs: 100,
            details: nil
        )

        // When: Handling tool end
        coordinator.handleToolEnd(event, context: mockContext)

        // Then: Thinking state should be reset for new block
        XCTAssertTrue(mockContext.resetThinkingForNewBlockCalled)
    }

    func testToolEndFinalizesThinkingBeforeReset() async throws {
        // Given: A tool end event
        let event = ToolEndPlugin.Result(
            toolCallId: "tool_thinking_finalize",
            success: true,
            displayResult: "Done",
            durationMs: 100,
            details: nil
        )

        // When: Handling tool end
        coordinator.handleToolEnd(event, context: mockContext)

        // Then: Thinking should be finalized and then reset
        XCTAssertTrue(mockContext.finalizeThinkingMessageIfNeededCalled)
        XCTAssertTrue(mockContext.resetThinkingForNewBlockCalled)
    }

    func testAskUserQuestionToolEndAlsoResetsThinkingState() async throws {
        // Given: An AskUserQuestion message exists
        let askData = AskUserQuestionToolData(
            toolCallId: "ask_thinking_reset",
            params: AskUserQuestionParams(
                questions: [
                    AskUserQuestion(
                        id: "q1",
                        question: "Pick?",
                        options: [
                            AskUserQuestionOption(label: "A", value: nil, description: nil)
                        ],
                        mode: .single,
                        allowOther: false,
                        otherPlaceholder: nil
                    )
                ],
                context: nil
            ),
            answers: [:],
            status: .pending,
            result: nil
        )
        mockContext.messages.append(ChatMessage(
            role: .assistant,
            content: .askUserQuestion(askData)
        ))

        // Given: Tool end arrives
        let event = ToolEndPlugin.Result(
            toolCallId: "ask_thinking_reset",
            success: true,
            displayResult: "",
            durationMs: 100,
            details: nil
        )

        // When: Handling tool end (AskUserQuestion returns early, but should still reset)
        coordinator.handleToolEnd(event, context: mockContext)

        // Then: Thinking state should still be reset (called at start of handleToolEnd)
        XCTAssertTrue(mockContext.resetThinkingForNewBlockCalled)
    }

    func testToolEndDoesNotEnqueueForAskUserQuestion() async throws {
        // Given: An AskUserQuestion message exists
        let askData = AskUserQuestionToolData(
            toolCallId: "ask_no_enqueue",
            params: AskUserQuestionParams(
                questions: [
                    AskUserQuestion(
                        id: "q1",
                        question: "Pick?",
                        options: [
                            AskUserQuestionOption(label: "A", value: nil, description: nil)
                        ],
                        mode: .single,
                        allowOther: false,
                        otherPlaceholder: nil
                    )
                ],
                context: nil
            ),
            answers: [:],
            status: .pending,
            result: nil
        )
        mockContext.messages.append(ChatMessage(
            role: .assistant,
            content: .askUserQuestion(askData)
        ))

        // Given: Tool end arrives
        let event = ToolEndPlugin.Result(
            toolCallId: "ask_no_enqueue",
            success: true,
            displayResult: "",
            durationMs: 100,
            details: nil
        )

        // When: Handling tool end
        coordinator.handleToolEnd(event, context: mockContext)

        // Then: Should NOT enqueue (AskUserQuestion returns early)
        XCTAssertEqual(mockContext.enqueuedToolEnds.count, 0)
    }
}

// MARK: - Mock Context

/// Mock implementation of ToolEventContext for testing
@MainActor
final class MockToolEventContext: ToolEventContext {
    // MARK: - State
    var messages: [ChatMessage] = []
    let messageIndex = MessageIndex()
    var runningToolCount: Int = 0
    var currentToolMessages: [UUID: ChatMessage] = [:]
    var currentTurnToolCalls: [ToolCallRecord] = []

    // MARK: - State Objects
    var askUserQuestionCalledInTurn: Bool = false

    // MARK: - Tracking for Assertions
    var flushPendingTextUpdatesCalled = false
    var finalizeStreamingMessageCalled = false
    var visibleToolCallIds: Set<String> = []
    var enqueuedToolStarts: [UIUpdateQueue.ToolStartData] = []
    var enqueuedToolEnds: [UIUpdateQueue.ToolEndData] = []
    var askUserQuestionSheetOpened = false
    var openedAskUserQuestionData: AskUserQuestionToolData?
    var resetThinkingForNewBlockCalled = false
    var finalizeThinkingMessageIfNeededCalled = false

    // MARK: - Protocol Methods

    func flushPendingTextUpdates() {
        flushPendingTextUpdatesCalled = true
    }

    func finalizeStreamingMessage() {
        finalizeStreamingMessageCalled = true
    }

    func makeToolVisible(_ toolCallId: String) {
        visibleToolCallIds.insert(toolCallId)
    }

    func enqueueToolStart(_ data: UIUpdateQueue.ToolStartData) {
        enqueuedToolStarts.append(data)
    }

    func enqueueToolEnd(_ data: UIUpdateQueue.ToolEndData) {
        enqueuedToolEnds.append(data)
    }

    func openAskUserQuestionSheet(for data: AskUserQuestionToolData) {
        askUserQuestionSheetOpened = true
        openedAskUserQuestionData = data
    }

    var getConfirmationCalledInTurn = false
    var getConfirmationSheetOpened = false
    var openedGetConfirmationData: GetConfirmationToolData?

    func openGetConfirmationSheet(for data: GetConfirmationToolData) {
        getConfirmationSheetOpened = true
        openedGetConfirmationData = data
    }

    func resetThinkingForNewBlock() {
        resetThinkingForNewBlockCalled = true
    }

    func finalizeThinkingMessageIfNeeded() {
        finalizeThinkingMessageIfNeededCalled = true
    }

    // MARK: - Logging (no-op for tests)
    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
    func showError(_ message: String) {}
}

// MARK: - Test Helper Extensions

/// Test-only initializer matching the historical ToolStartEvent constructor.
extension ToolStartPlugin.Result {
    init(toolName: String, toolCallId: String, arguments: [String: AnyCodable]?, formattedArguments: String) {
        // Parse formattedArguments back to arguments if arguments is nil
        var args = arguments
        if args == nil && !formattedArguments.isEmpty {
            if let data = formattedArguments.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String: AnyCodable].self, from: data) {
                args = parsed
            }
        }
        self.init(toolName: toolName, toolCallId: toolCallId, arguments: args)
    }
}

/// Test-only initializer matching the historical ToolEndEvent constructor.
extension ToolEndPlugin.Result {
    init(toolCallId: String, success: Bool, displayResult: String, durationMs: Int?, details: ToolEndPlugin.EventData.ToolDetails?) {
        self.init(
            toolCallId: toolCallId,
            toolName: nil,
            success: success,
            output: success ? displayResult : nil,
            error: success ? nil : displayResult,
            duration: durationMs,
            details: details,
            rawDetails: nil
        )
    }
}
