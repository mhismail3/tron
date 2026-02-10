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

    func testToolGeneratingSkipsAskUserQuestion() async throws {
        let result = ToolGeneratingPlugin.Result(toolName: "AskUserQuestion", toolCallId: "gen_ask")

        coordinator.handleToolGenerating(result, context: mockContext)

        XCTAssertEqual(mockContext.messages.count, 0)
    }

    func testToolGeneratingSkipsRenderAppUI() async throws {
        let result = ToolGeneratingPlugin.Result(toolName: "RenderAppUI", toolCallId: "gen_render")

        coordinator.handleToolGenerating(result, context: mockContext)

        XCTAssertEqual(mockContext.messages.count, 0)
    }

    func testToolGeneratingSkipsOpenURL() async throws {
        let result = ToolGeneratingPlugin.Result(toolName: "OpenURL", toolCallId: "gen_openurl")

        coordinator.handleToolGenerating(result, context: mockContext)

        XCTAssertEqual(mockContext.messages.count, 0)
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
        let startResult = ToolStartResult(
            tool: ToolUseData(
                toolName: "Write",
                toolCallId: "gen_first",
                arguments: "{\"file_path\":\"/test.txt\"}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: false,
            isOpenURL: false,
            askUserQuestionParams: nil,
            openURL: nil
        )
        coordinator.handleToolStart(event, result: startResult, context: mockContext)

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
        // Then: Message window is updated
        XCTAssertEqual(mockContext.updatedInMessageWindow.count, 1)
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
        let endResult = ToolEndResult(
            toolCallId: "gen_end",
            status: .success,
            result: "File written",
            durationMs: 150,
            isAskUserQuestion: false
        )
        coordinator.handleToolEnd(endEvent, result: endResult, context: mockContext)

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

    func testBrowserToolStartStillTriggersOnDuplicate() async throws {
        // Given: tool_generating already created a chip for a browser tool
        let genResult = ToolGeneratingPlugin.Result(toolName: "BrowseTheWeb", toolCallId: "browser_dup")
        coordinator.handleToolGenerating(genResult, context: mockContext)
        XCTAssertEqual(mockContext.messages.count, 1)

        // When: tool_start arrives with isBrowserTool: true and full arguments
        let event = ToolStartPlugin.Result(
            toolName: "BrowseTheWeb",
            toolCallId: "browser_dup",
            arguments: ["action": AnyCodable("navigate"), "url": AnyCodable("https://example.com")],
            formattedArguments: "{\"action\":\"navigate\",\"url\":\"https://example.com\"}"
        )
        let startResult = ToolStartResult(
            tool: ToolUseData(
                toolName: "BrowseTheWeb",
                toolCallId: "browser_dup",
                arguments: "{\"action\":\"navigate\",\"url\":\"https://example.com\"}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: true,
            isOpenURL: false,
            askUserQuestionParams: nil,
            openURL: nil
        )
        coordinator.handleToolStart(event, result: startResult, context: mockContext)

        // Then: No duplicate message
        XCTAssertEqual(mockContext.messages.count, 1)
        // Then: Arguments are updated
        if case .toolUse(let tool) = mockContext.messages[0].content {
            XCTAssertTrue(tool.arguments.contains("navigate"))
        } else {
            XCTFail("Expected toolUse content")
        }
        // Then: Browser status is still set
        XCTAssertNotNil(mockContext.browserStatus)
        // Then: Browser streaming is started
        XCTAssertTrue(mockContext.startBrowserStreamIfNeededCalled)
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
            isOpenURL: false,
            askUserQuestionParams: nil,
            openURL: nil
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
            isOpenURL: false,
            askUserQuestionParams: nil,
            openURL: nil
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, result: result, context: mockContext)

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
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "Read",
                toolCallId: "tool_thinking_start",
                arguments: "{}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: false,
            isOpenURL: false,
            askUserQuestionParams: nil,
            openURL: nil
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, result: result, context: mockContext)

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
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "Grep",
                toolCallId: "tool_789",
                arguments: "{\"pattern\": \"TODO\"}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: false,
            isOpenURL: false,
            askUserQuestionParams: nil,
            openURL: nil
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
            isOpenURL: false,
            askUserQuestionParams: nil,
            openURL: nil
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
            isOpenURL: false,
            askUserQuestionParams: nil,
            openURL: nil
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
            isOpenURL: false,
            askUserQuestionParams: params,
            openURL: nil
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
            isOpenURL: false,
            askUserQuestionParams: nil, // Parse failed
            openURL: nil
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

    // MARK: - OpenURL Tool Tests

    func testOpenURLToolStart() async throws {
        // Given: An OpenURL tool start
        let url = URL(string: "https://example.com")!
        let event = ToolStartPlugin.Result(
            toolName: "OpenURL",
            toolCallId: "browser_123",
            arguments: ["url": AnyCodable("https://example.com")],
            formattedArguments: "{\"url\": \"https://example.com\"}"
        )
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "OpenURL",
                toolCallId: "browser_123",
                arguments: "{\"url\": \"https://example.com\"}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: false,
            isOpenURL: true,
            askUserQuestionParams: nil,
            openURL: url
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, result: result, context: mockContext)

        // Then: Should set Safari URL
        XCTAssertEqual(mockContext.safariURL, url)

        // Then: Should ALSO create regular tool message (don't return early)
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .toolUse(let tool) = mockContext.messages[0].content {
            XCTAssertEqual(tool.toolName, "OpenURL")
        } else {
            XCTFail("Expected toolUse content")
        }
    }

    // MARK: - Browser Tool Tests

    func testBrowserToolStartUpdatesBrowserStatus() async throws {
        // Given: A browser tool start
        let event = ToolStartPlugin.Result(
            toolName: "BrowseTheWeb",
            toolCallId: "browser_snap",
            arguments: nil,
            formattedArguments: "{}"
        )
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "BrowseTheWeb",
                toolCallId: "browser_snap",
                arguments: "{}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: true,
            isOpenURL: false,
            askUserQuestionParams: nil,
            openURL: nil
        )

        // When: Handling tool start (browserStatus is initially nil)
        XCTAssertNil(mockContext.browserStatus)
        XCTAssertFalse(mockContext.showBrowserWindow)
        coordinator.handleToolStart(event, result: result, context: mockContext)

        // Then: Browser status should be set
        XCTAssertNotNil(mockContext.browserStatus)
        XCTAssertTrue(mockContext.browserStatus?.hasBrowser ?? false)

        // Then: Browser window should be auto-shown
        XCTAssertTrue(mockContext.showBrowserWindow)

        // Then: Browser streaming should be requested
        XCTAssertTrue(mockContext.startBrowserStreamIfNeededCalled)
    }

    func testBrowserToolStartRespectsUserDismissal() async throws {
        // Given: User has dismissed browser this turn
        mockContext.browserDismissal = .userDismissed

        // Given: A browser tool start
        let event = ToolStartPlugin.Result(
            toolName: "BrowseTheWeb",
            toolCallId: "browser_dismissed",
            arguments: nil,
            formattedArguments: "{}"
        )
        let result = ToolStartResult(
            tool: ToolUseData(
                toolName: "BrowseTheWeb",
                toolCallId: "browser_dismissed",
                arguments: "{}",
                status: .running
            ),
            isAskUserQuestion: false,
            isBrowserTool: true,
            isOpenURL: false,
            askUserQuestionParams: nil,
            openURL: nil
        )

        // When: Handling tool start
        coordinator.handleToolStart(event, result: result, context: mockContext)

        // Then: Browser status should still be set
        XCTAssertNotNil(mockContext.browserStatus)

        // Then: Browser window should NOT be auto-shown (user dismissed)
        XCTAssertFalse(mockContext.showBrowserWindow)

        // Then: Browser streaming should NOT be requested
        XCTAssertFalse(mockContext.startBrowserStreamIfNeededCalled)
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
            isOpenURL: false,
            askUserQuestionParams: nil,
            openURL: nil
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
            isOpenURL: false,
            askUserQuestionParams: nil,
            openURL: nil
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
        let result = ToolEndResult(
            toolCallId: "tool_thinking_reset",
            status: .success,
            result: "Done",
            durationMs: 100,
            isAskUserQuestion: false
        )

        // When: Handling tool end
        coordinator.handleToolEnd(event, result: result, context: mockContext)

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
        let result = ToolEndResult(
            toolCallId: "tool_thinking_finalize",
            status: .success,
            result: "Done",
            durationMs: 100,
            isAskUserQuestion: false
        )

        // When: Handling tool end
        coordinator.handleToolEnd(event, result: result, context: mockContext)

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
        let result = ToolEndResult(
            toolCallId: "ask_thinking_reset",
            status: .success,
            result: "",
            durationMs: 100,
            isAskUserQuestion: false
        )

        // When: Handling tool end (AskUserQuestion returns early, but should still reset)
        coordinator.handleToolEnd(event, result: result, context: mockContext)

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
    var showBrowserWindow: Bool = false
    var browserDismissal: BrowserDismissal = .none

    // MARK: - Tracking for Assertions
    var flushPendingTextUpdatesCalled = false
    var finalizeStreamingMessageCalled = false
    var visibleToolCallIds: Set<String> = []
    var appendedToMessageWindow: [ChatMessage] = []
    var updatedInMessageWindow: [ChatMessage] = []
    var enqueuedToolStarts: [UIUpdateQueue.ToolStartData] = []
    var enqueuedToolEnds: [UIUpdateQueue.ToolEndData] = []
    var askUserQuestionSheetOpened = false
    var openedAskUserQuestionData: AskUserQuestionToolData?
    var resetThinkingForNewBlockCalled = false
    var finalizeThinkingMessageIfNeededCalled = false
    var startBrowserStreamIfNeededCalled = false

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

    func updateInMessageWindow(_ message: ChatMessage) {
        updatedInMessageWindow.append(message)
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

    @discardableResult
    func updateBrowserStatusIfNeeded() -> Bool {
        let shouldShow = browserDismissal != .userDismissed
        if browserStatus == nil {
            browserStatus = BrowserGetStatusResult(hasBrowser: true, isStreaming: false, currentUrl: nil)
        }
        if shouldShow && !showBrowserWindow {
            showBrowserWindow = true
        }
        return shouldShow
    }

    func startBrowserStreamIfNeeded() {
        startBrowserStreamIfNeededCalled = true
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
            details: details,
            rawDetails: nil
        )
    }
}
