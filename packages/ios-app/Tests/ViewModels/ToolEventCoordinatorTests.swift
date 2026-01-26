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

    // MARK: - Tool Start Tests

    func testToolStartCreatesToolMessage() async throws {
        // Given: A tool start event and result
        let event = ToolStartPlugin.Result(
            toolName: "Bash",
            toolCallId: "tool_123",
            arguments: nil,
            formattedArguments: "{\"command\": \"ls -la\"}"
        )
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "Bash",
                toolCallId: "tool_123",
                arguments: "{\"command\": \"ls -la\"}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: false,
            isOpenBrowser: false,
            askUserQuestionParams: nil,
            openBrowserURL: nil
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, result: result, context: mockContext)

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
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "Read",
                toolCallId: "tool_456",
                arguments: "{}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: false,
            isOpenBrowser: false,
            askUserQuestionParams: nil,
            openBrowserURL: nil
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, result: result, context: mockContext)

        // Then: Streaming text should be flushed first
        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testToolStartTracksToolCall() async throws {
        // Given: A tool start event
        let event = ToolStartPlugin.Result(
            toolName: "Grep",
            toolCallId: "tool_789",
            arguments: nil,
            formattedArguments: "{\"pattern\": \"TODO\"}"
        )
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "Grep",
                toolCallId: "tool_789",
                arguments: "{\"pattern\": \"TODO\"}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: false,
            isOpenBrowser: false,
            askUserQuestionParams: nil,
            openBrowserURL: nil
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, result: result, context: mockContext)

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
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "Edit",
                toolCallId: "tool_visible",
                arguments: "{}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: false,
            isOpenBrowser: false,
            askUserQuestionParams: nil,
            openBrowserURL: nil
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, result: result, context: mockContext)

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
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "Write",
                toolCallId: "tool_queue",
                arguments: "{}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: false,
            isOpenBrowser: false,
            askUserQuestionParams: nil,
            openBrowserURL: nil
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, result: result, context: mockContext)

        // Then: Should be enqueued for ordered processing
        XCTAssertEqual(mockContext.enqueuedToolStarts.count, 1)
        XCTAssertEqual(mockContext.enqueuedToolStarts[0].toolCallId, "tool_queue")
    }

    // MARK: - AskUserQuestion Tool Tests

    func testAskUserQuestionToolStart() async throws {
        // Given: An AskUserQuestion tool start
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
        let event = ToolStartPlugin.Result(
            toolName: "AskUserQuestion",
            toolCallId: "ask_123",
            arguments: nil,
            formattedArguments: "{}"
        )
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "AskUserQuestion",
                toolCallId: "ask_123",
                arguments: "{}",
                status: .running
            ),
            isAskUserQuestion: true,
            isBrowserTool: false,
            isOpenBrowser: false,
            askUserQuestionParams: params,
            openBrowserURL: nil
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, result: result, context: mockContext)

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
        // Given: An AskUserQuestion tool start WITHOUT params (parse failed)
        let event = ToolStartPlugin.Result(
            toolName: "AskUserQuestion",
            toolCallId: "ask_fail",
            arguments: nil,
            formattedArguments: "invalid json"
        )
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "AskUserQuestion",
                toolCallId: "ask_fail",
                arguments: "invalid json",
                status: .running
            ),
            isAskUserQuestion: true,
            isBrowserTool: false,
            isOpenBrowser: false,
            askUserQuestionParams: nil, // Parse failed
            openBrowserURL: nil
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, result: result, context: mockContext)

        // Then: Should fall back to regular tool display
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .toolUse(let tool) = mockContext.messages[0].content {
            XCTAssertEqual(tool.toolName, "AskUserQuestion")
        } else {
            XCTFail("Expected toolUse content for fallback")
        }
    }

    // MARK: - OpenBrowser Tool Tests

    func testOpenBrowserToolStart() async throws {
        // Given: An OpenBrowser tool start
        let url = URL(string: "https://example.com")!
        let event = ToolStartPlugin.Result(
            toolName: "OpenBrowser",
            toolCallId: "browser_123",
            arguments: ["url": AnyCodable("https://example.com")],
            formattedArguments: "{\"url\": \"https://example.com\"}"
        )
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "OpenBrowser",
                toolCallId: "browser_123",
                arguments: "{\"url\": \"https://example.com\"}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: false,
            isOpenBrowser: true,
            askUserQuestionParams: nil,
            openBrowserURL: url
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, result: result, context: mockContext)

        // Then: Should set Safari URL
        XCTAssertEqual(mockContext.safariURL, url)

        // Then: Should ALSO create regular tool message (don't return early)
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .toolUse(let tool) = mockContext.messages[0].content {
            XCTAssertEqual(tool.toolName, "OpenBrowser")
        } else {
            XCTFail("Expected toolUse content")
        }
    }

    // MARK: - Browser Tool Tests

    func testBrowserToolStartUpdatesBrowserStatus() async throws {
        // Given: A browser tool start
        let event = ToolStartPlugin.Result(
            toolName: "browser_snapshot",
            toolCallId: "browser_snap",
            arguments: nil,
            formattedArguments: "{}"
        )
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "browser_snapshot",
                toolCallId: "browser_snap",
                arguments: "{}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: true,
            isOpenBrowser: false,
            askUserQuestionParams: nil,
            openBrowserURL: nil
        )

        // When: Handling tool start (browserStatus is initially nil)
        XCTAssertNil(mockContext.browserStatus)
        coordinator.handleToolStart(event, result: result, context: mockContext)

        // Then: Browser status should be set
        XCTAssertNotNil(mockContext.browserStatus)
        XCTAssertTrue(mockContext.browserStatus?.hasBrowser ?? false)
    }

    // MARK: - RenderAppUI Tool Tests

    func testRenderAppUIToolStartCreatesChip() async throws {
        // Given: A RenderAppUI tool start
        let event = ToolStartPlugin.Result(
            toolName: "RenderAppUI",
            toolCallId: "render_123",
            arguments: ["canvasId": AnyCodable("canvas_abc"), "title": AnyCodable("My App")],
            formattedArguments: "{\"canvasId\": \"canvas_abc\", \"title\": \"My App\"}"
        )
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "RenderAppUI",
                toolCallId: "render_123",
                arguments: "{\"canvasId\": \"canvas_abc\", \"title\": \"My App\"}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: false,
            isOpenBrowser: false,
            askUserQuestionParams: nil,
            openBrowserURL: nil
        )

        // When: Handling tool start (no prior chunk)
        coordinator.handleToolStart(event, result: result, context: mockContext)

        // Then: Should create RenderAppUI chip message
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .renderAppUI(let chipData) = mockContext.messages[0].content {
            XCTAssertEqual(chipData.toolCallId, "render_123")
            XCTAssertEqual(chipData.canvasId, "canvas_abc")
            XCTAssertEqual(chipData.title, "My App")
            XCTAssertEqual(chipData.status, .rendering)
        } else {
            XCTFail("Expected renderAppUI content")
        }

        // Then: Should track in chip tracker
        XCTAssertTrue(mockContext.renderAppUIChipTracker.hasChip(canvasId: "canvas_abc"))
    }

    func testRenderAppUIToolStartUpdatesExistingChipFromChunk() async throws {
        // Given: A chip already exists from earlier chunk (with placeholder toolCallId)
        let messageId = UUID()
        let existingMessage = ChatMessage(
            id: messageId,
            role: .assistant,
            content: .renderAppUI(RenderAppUIChipData(
                toolCallId: "pending_canvas_xyz",
                canvasId: "canvas_xyz",
                title: "My App",
                status: .rendering,
                errorMessage: nil
            ))
        )
        mockContext.messages.append(existingMessage)
        _ = mockContext.renderAppUIChipTracker.createChipFromChunk(
            canvasId: "canvas_xyz",
            messageId: messageId,
            title: "My App"
        )

        // Given: Tool start arrives with real toolCallId
        let event = ToolStartPlugin.Result(
            toolName: "RenderAppUI",
            toolCallId: "render_real_456",
            arguments: ["canvasId": AnyCodable("canvas_xyz"), "title": AnyCodable("My App")],
            formattedArguments: "{\"canvasId\": \"canvas_xyz\", \"title\": \"My App\"}"
        )
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "RenderAppUI",
                toolCallId: "render_real_456",
                arguments: "{\"canvasId\": \"canvas_xyz\", \"title\": \"My App\"}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: false,
            isOpenBrowser: false,
            askUserQuestionParams: nil,
            openBrowserURL: nil
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, result: result, context: mockContext)

        // Then: Should NOT create new message (update existing)
        XCTAssertEqual(mockContext.messages.count, 1)

        // Then: Should update toolCallId to real one
        if case .renderAppUI(let chipData) = mockContext.messages[0].content {
            XCTAssertEqual(chipData.toolCallId, "render_real_456")
        } else {
            XCTFail("Expected renderAppUI content")
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
        let result = ToolEndResult(
            toolCallId: "tool_end_123",
            status: .success,
            result: "Success!",
            durationMs: 150,
            isAskUserQuestion: false
        )

        // When: Handling tool end
        coordinator.handleToolEnd(event, result: result, context: mockContext)

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
        let result = ToolEndResult(
            toolCallId: "tool_track_123",
            status: .error,
            result: "Command failed",
            durationMs: 50,
            isAskUserQuestion: false
        )

        // When: Handling tool end
        coordinator.handleToolEnd(event, result: result, context: mockContext)

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
        let result = ToolEndResult(
            toolCallId: "ask_sheet_123",
            status: .success,
            result: "",
            durationMs: 100,
            isAskUserQuestion: false // Coordinator determines this from message content
        )

        // When: Handling tool end
        coordinator.handleToolEnd(event, result: result, context: mockContext)

        // Then: Sheet should be opened
        XCTAssertTrue(mockContext.askUserQuestionSheetOpened)
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
        let result = ToolEndResult(
            toolCallId: "ask_no_enqueue",
            status: .success,
            result: "",
            durationMs: 100,
            isAskUserQuestion: false
        )

        // When: Handling tool end
        coordinator.handleToolEnd(event, result: result, context: mockContext)

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
    var currentToolMessages: [UUID: ChatMessage] = [:]
    var currentTurnToolCalls: [ToolCallRecord] = []

    // MARK: - State Objects
    var askUserQuestionCalledInTurn: Bool = false
    var browserStatus: BrowserGetStatusResult?
    var safariURL: URL?
    let renderAppUIChipTracker = RenderAppUIChipTracker()

    // MARK: - Tracking for Assertions
    var flushPendingTextUpdatesCalled = false
    var finalizeStreamingMessageCalled = false
    var visibleToolCallIds: Set<String> = []
    var appendedToMessageWindow: [ChatMessage] = []
    var enqueuedToolStarts: [UIUpdateQueue.ToolStartData] = []
    var enqueuedToolEnds: [UIUpdateQueue.ToolEndData] = []
    var askUserQuestionSheetOpened = false
    var openedAskUserQuestionData: AskUserQuestionToolData?

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

    func appendToMessageWindow(_ message: ChatMessage) {
        appendedToMessageWindow.append(message)
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

    func updateBrowserStatusIfNeeded() {
        if browserStatus == nil {
            browserStatus = BrowserGetStatusResult(hasBrowser: true, isStreaming: false, currentUrl: nil)
        }
    }

    // MARK: - Logging (no-op for tests)
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}

// MARK: - Test Helper Extensions

/// Test-only initializer matching legacy ToolStartEvent constructor
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

/// Test-only initializer matching legacy ToolEndEvent constructor
extension ToolEndPlugin.Result {
    init(toolCallId: String, success: Bool, displayResult: String, durationMs: Int?, details: ToolEndPlugin.EventData.ToolDetails?) {
        self.init(
            toolCallId: toolCallId,
            toolName: nil,
            success: success,
            result: success ? displayResult : nil,
            error: success ? nil : displayResult,
            durationMs: durationMs,
            details: details
        )
    }
}
