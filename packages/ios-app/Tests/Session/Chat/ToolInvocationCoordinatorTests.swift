import XCTest
@testable import TronMobile

/// Tests for ToolInvocationCoordinator - handles tool start/end UI coordination
/// Uses TDD: Tests written first, then implementation follows
@MainActor
final class ToolInvocationCoordinatorTests: XCTestCase {

    var coordinator: ToolInvocationCoordinator!
    var mockContext: MockToolInvocationContext!

    override func setUp() async throws {
        mockContext = MockToolInvocationContext()
        coordinator = ToolInvocationCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - Tool Generating Tests

    func testToolInvocationGeneratingCreatesRunningChip() async throws {
        // Given: A tool generating event
        let result = ToolInvocationGeneratingPlugin.Result(
            toolName: "filesystem_write",
            invocationId: "gen_123",
            identity: ToolIdentity(toolName: "filesystem_write")
        )

        // When: Handling tool generating
        coordinator.handleToolInvocationGenerating(result, context: mockContext)

        // Then: A tool invocation should be created with .generating status
        XCTAssertEqual(mockContext.messages.count, 1)
        XCTAssertEqual(mockContext.messages[0].role, .assistant)
        if case .toolInvocation(let invocation) = mockContext.messages[0].content {
            XCTAssertEqual(invocation.identity.toolName, "filesystem_write")
            XCTAssertEqual(invocation.id, "gen_123")
            XCTAssertEqual(invocation.status, .generating)
            XCTAssertEqual(invocation.arguments, "")
        } else {
            XCTFail("Expected tool invocation content")
        }
    }

    func testToolInvocationGeneratingFinalizesThinkingMessage() async throws {
        let result = ToolInvocationGeneratingPlugin.Result(toolName: "process_run", invocationId: "gen_think")

        coordinator.handleToolInvocationGenerating(result, context: mockContext)

        XCTAssertTrue(mockContext.finalizeThinkingMessageIfNeededCalled)
    }

    func testToolInvocationGeneratingFlushesStreamingText() async throws {
        let result = ToolInvocationGeneratingPlugin.Result(toolName: "process_run", invocationId: "gen_flush")

        coordinator.handleToolInvocationGenerating(result, context: mockContext)

        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testToolInvocationGeneratingMakesToolVisible() async throws {
        let result = ToolInvocationGeneratingPlugin.Result(toolName: "process_run", invocationId: "gen_vis")

        coordinator.handleToolInvocationGenerating(result, context: mockContext)

        XCTAssertTrue(mockContext.visibleInvocationIds.contains("gen_vis"))
    }

    func testToolInvocationGeneratingEnqueuesToolInvocationStart() async throws {
        let result = ToolInvocationGeneratingPlugin.Result(toolName: "process_run", invocationId: "gen_enq")

        coordinator.handleToolInvocationGenerating(result, context: mockContext)

        XCTAssertEqual(mockContext.enqueuedToolStarts.count, 1)
        XCTAssertEqual(mockContext.enqueuedToolStarts[0].invocationId, "gen_enq")
        XCTAssertEqual(mockContext.enqueuedToolStarts[0].toolName, "process_run")
    }

    func testToolInvocationGeneratingSkipsDuplicateChip() async throws {
        // Given: A tool message already exists
        let existing = ChatMessage(
            role: .assistant,
            content: .toolInvocation(testToolInvocation(
                id: "dup_123",
                status: .running,
                identity: testToolIdentity(toolName: "process_run")
            ))
        )
        mockContext.messages.append(existing)

        // When: tool.invocation.generating arrives for same invocationId
        let result = ToolInvocationGeneratingPlugin.Result(toolName: "process_run", invocationId: "dup_123")
        coordinator.handleToolInvocationGenerating(result, context: mockContext)

        // Then: No duplicate message created
        XCTAssertEqual(mockContext.messages.count, 1)
    }

    func testToolInvocationStartUpdatesDuplicateFromGenerating() async throws {
        // Given: tool.invocation.generating already created a chip with empty arguments
        let genResult = ToolInvocationGeneratingPlugin.Result(toolName: "process_run", invocationId: "gen_first")
        coordinator.handleToolInvocationGenerating(genResult, context: mockContext)
        XCTAssertEqual(mockContext.messages.count, 1)

        // When: tool.invocation.started arrives for same invocationId with full arguments
        let event = ToolInvocationStartedPlugin.Result(
            toolName: "process_run",
            invocationId: "gen_first",
            arguments: ["file_path": AnyCodable("/test.txt")],
            formattedArguments: "{\"file_path\":\"/test.txt\"}"
        )
        coordinator.handleToolInvocationStarted(event, context: mockContext)

        // Then: No duplicate message (still just 1)
        XCTAssertEqual(mockContext.messages.count, 1)
        // Then: Tool is still visible
        XCTAssertTrue(mockContext.visibleInvocationIds.contains("gen_first"))
        // Then: Arguments are updated from empty to full
        if case .toolInvocation(let invocation) = mockContext.messages[0].content {
            XCTAssertFalse(invocation.arguments.isEmpty, "Arguments should be updated from empty")
            XCTAssertTrue(invocation.arguments.contains("file_path"), "Arguments should contain the file_path")
        } else {
            XCTFail("Expected tool invocation content")
        }
        // Then: current-turn membership tracks only the authoritative message identity.
        XCTAssertEqual(mockContext.currentTurnToolMessageIds, [mockContext.messages[0].id])
    }

    func testToolInvocationEndUpdatesGeneratingChip() async throws {
        // Given: tool.invocation.generating created a chip
        let genResult = ToolInvocationGeneratingPlugin.Result(toolName: "process_run", invocationId: "gen_end")
        coordinator.handleToolInvocationGenerating(genResult, context: mockContext)

        // When: tool.invocation.completed arrives
        let endEvent = ToolInvocationCompletedPlugin.Result(
            invocationId: "gen_end",
            success: true,
            displayResult: "File written",
            durationMs: 150,
            details: nil
        )
        coordinator.handleToolInvocationCompleted(endEvent, context: mockContext)

        // Then: The authoritative completion update is enqueued.
        XCTAssertEqual(mockContext.enqueuedToolEnds.count, 1)
        XCTAssertEqual(mockContext.enqueuedToolEnds[0].result, "File written")
        XCTAssertTrue(mockContext.enqueuedToolEnds[0].success)
    }

    func testMultipleToolGeneratingEvents() async throws {
        // When: Two tool.invocation.generating events arrive
        coordinator.handleToolInvocationGenerating(
            ToolInvocationGeneratingPlugin.Result(
                toolName: "filesystem_write",
                invocationId: "tc1",
                identity: ToolIdentity(toolName: "filesystem_write")
            ),
            context: mockContext
        )
        coordinator.handleToolInvocationGenerating(
            ToolInvocationGeneratingPlugin.Result(
                toolName: "process_run",
                invocationId: "tc2",
                identity: ToolIdentity(toolName: "process_run")
            ),
            context: mockContext
        )

        // Then: Two messages created
        XCTAssertEqual(mockContext.messages.count, 2)
        // Then: Both have .generating status
        if case .toolInvocation(let invocation1) = mockContext.messages[0].content {
            XCTAssertEqual(invocation1.status, .generating)
            XCTAssertEqual(invocation1.identity.toolName, "filesystem_write")
        } else { XCTFail("Expected tool invocation content") }
        if case .toolInvocation(let invocation2) = mockContext.messages[1].content {
            XCTAssertEqual(invocation2.status, .generating)
            XCTAssertEqual(invocation2.identity.toolName, "process_run")
        } else { XCTFail("Expected tool invocation content") }
        // Then: Two enqueued tool starts
        XCTAssertEqual(mockContext.enqueuedToolStarts.count, 2)
        XCTAssertEqual(mockContext.enqueuedToolStarts[0].invocationId, "tc1")
        XCTAssertEqual(mockContext.enqueuedToolStarts[1].invocationId, "tc2")
    }

    // MARK: - Tool Start Tests

    func testUserInputLifecycleUsesNativeRequestInsteadOfGenericToolChip() async throws {
        let event = ToolInvocationStartedPlugin.Result(
            toolName: "request_user_input",
            invocationId: "question-1",
            arguments: [
                "questions": AnyCodable([[
                    "header": "Format",
                    "id": "format",
                    "question": "Which format should I use?",
                    "options": [
                        ["label": "Markdown", "description": "Write a Markdown file."],
                        ["label": "HTML", "description": "Write an HTML file."]
                    ]
                ]])
            ],
            formattedArguments: ""
        )

        coordinator.handleToolInvocationStarted(event, context: mockContext)

        XCTAssertEqual(mockContext.messages.count, 1)
        XCTAssertEqual(mockContext.runningToolInvocationCount, 0)
        XCTAssertTrue(mockContext.enqueuedToolStarts.isEmpty)
        let pending = try XCTUnwrap(mockContext.pendingUserInputRequest)
        XCTAssertEqual(pending.invocationId, "question-1")
        XCTAssertEqual(pending.questions.first?.options.map(\.label), ["Markdown", "HTML"])
        XCTAssertEqual(mockContext.userInputAutoPresentationInvocationId, "question-1")

        coordinator.handleToolInvocationCompleted(
            ToolInvocationCompletedPlugin.Result(
                invocationId: "question-1",
                toolName: "request_user_input",
                isError: false,
                content: "Question presented",
                duration: 1,
                details: nil,
                rawDetails: nil,
                identity: ToolIdentity()
            ),
            context: mockContext
        )
        XCTAssertEqual(mockContext.pendingUserInputRequest?.status, .pending)
        XCTAssertTrue(mockContext.enqueuedToolEnds.isEmpty)

        coordinator.handleToolInvocationStarted(event, context: mockContext)
        XCTAssertEqual(mockContext.messages.count, 1, "replayed start must be idempotent")
    }

    func testMalformedUserInputDoesNotCreateAnUnanswerableSheet() {
        let event = ToolInvocationStartedPlugin.Result(
            toolName: "request_user_input",
            invocationId: "question-bad",
            arguments: [
                "questions": AnyCodable([[
                    "header": "Format",
                    "id": "format",
                    "question": "Which format?",
                    "options": [
                        ["label": "Other", "description": "Duplicate native Other"],
                        ["label": "HTML", "description": "HTML file"]
                    ]
                ]])
            ],
            formattedArguments: ""
        )

        coordinator.handleToolInvocationStarted(event, context: mockContext)

        XCTAssertTrue(mockContext.messages.isEmpty)
        XCTAssertNil(mockContext.pendingUserInputRequest)
    }

    func testToolInvocationStartCreatesToolMessage() async throws {
        // Given: A tool start event
        let event = ToolInvocationStartedPlugin.Result(
            toolName: "process_run",
            invocationId: "inv_123",
            arguments: nil,
            formattedArguments: "{\"command\": \"ls -la\"}",
            identity: ToolIdentity(toolName: "process_run")
        )

        // When: Handling tool start
        coordinator.handleToolInvocationStarted(event, context: mockContext)

        // Then: A tool message should be created
        XCTAssertEqual(mockContext.messages.count, 1)
        XCTAssertEqual(mockContext.messages[0].role, .assistant)
        if case .toolInvocation(let invocation) = mockContext.messages[0].content {
            XCTAssertEqual(invocation.identity.toolName, "process_run")
            XCTAssertEqual(invocation.id, "inv_123")
            XCTAssertEqual(invocation.status, .running)
        } else {
            XCTFail("Expected tool invocation content")
        }
    }

    func testStreamedToolStartProjectsWorkSummary() async throws {
        let event = ToolInvocationStartedPlugin.Result(
            toolName: "process_run",
            invocationId: "work_stream_123",
            arguments: [
                "operation": AnyCodable("process_run"),
                "intent": AnyCodable("Check repository state."),
                "payload": AnyCodable([
                    "command": "git status --short",
                    "executionMode": "read_only"
                ]),
                "reason": AnyCodable("User asked for current repository state.")
            ],
            formattedArguments: "{}",
            identity: ToolIdentity(
                toolName: "process_run",
                traceId: "trace-process"
            )
        )

        coordinator.handleToolInvocationStarted(event, context: mockContext)

        XCTAssertEqual(mockContext.messages.count, 1)
        if case .toolInvocation(let invocation) = mockContext.messages[0].content {
            XCTAssertEqual(invocation.display.primitiveTitle, "Process Run")
            XCTAssertEqual(invocation.display.chipTitle, "Process Run")
            XCTAssertTrue(invocation.display.actionRows.contains(ToolDisplayRow(label: "Trace", value: "trace-proces")))
            XCTAssertTrue(invocation.display.actionRows.contains(ToolDisplayRow(label: "Why", value: "User asked for current repository state.")))
            let visibleProjection = [
                invocation.display.primitiveTitle,
                invocation.display.chipTitle,
                invocation.display.commandText,
                invocation.display.summaryText
            ].joined(separator: " ")
            XCTAssertFalse(visibleProjection.contains("process_run"))
            XCTAssertFalse(visibleProjection.contains("first_party"))
        } else {
            XCTFail("Expected tool invocation content")
        }
    }

    func testToolInvocationStartFlushesStreamingTextFirst() async throws {
        // Given: A tool start event
        let event = ToolInvocationStartedPlugin.Result(
            toolName: "process_run",
            invocationId: "inv_456",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling tool start
        coordinator.handleToolInvocationStarted(event, context: mockContext)

        // Then: Streaming text should be flushed first
        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testToolInvocationStartFinalizesThinkingMessage() async throws {
        // Given: A tool start event
        let event = ToolInvocationStartedPlugin.Result(
            toolName: "process_run",
            invocationId: "inv_thinking_start",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling tool start
        coordinator.handleToolInvocationStarted(event, context: mockContext)

        // Then: Thinking should be finalized
        XCTAssertTrue(mockContext.finalizeThinkingMessageIfNeededCalled)
    }

    func testToolInvocationStartMakesToolVisible() async throws {
        // Given: A tool start event
        let event = ToolInvocationStartedPlugin.Result(
            toolName: "process_run",
            invocationId: "inv_visible",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling tool start
        coordinator.handleToolInvocationStarted(event, context: mockContext)

        // Then: Tool should be made visible for animation
        XCTAssertTrue(mockContext.visibleInvocationIds.contains("inv_visible"))
    }

    func testToolInvocationStartEnqueuesForUIUpdateQueue() async throws {
        // Given: A tool start event
        let event = ToolInvocationStartedPlugin.Result(
            toolName: "process_run",
            invocationId: "inv_queue",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling tool start
        coordinator.handleToolInvocationStarted(event, context: mockContext)

        // Then: Should be enqueued for ordered processing
        XCTAssertEqual(mockContext.enqueuedToolStarts.count, 1)
        XCTAssertEqual(mockContext.enqueuedToolStarts[0].invocationId, "inv_queue")
    }

    // MARK: - Tool End Tests

    func testToolInvocationEndEnqueuesForProcessing() async throws {
        // Given: A tool end event
        let event = ToolInvocationCompletedPlugin.Result(
            invocationId: "tool.invocation.completed_123",
            success: true,
            displayResult: "Success!",
            durationMs: 150,
            details: nil
        )

        // When: Handling tool end
        coordinator.handleToolInvocationCompleted(event, context: mockContext)

        // Then: Should enqueue for ordered processing
        XCTAssertEqual(mockContext.enqueuedToolEnds.count, 1)
        XCTAssertEqual(mockContext.enqueuedToolEnds[0].invocationId, "tool.invocation.completed_123")
        XCTAssertTrue(mockContext.enqueuedToolEnds[0].success)
    }

    // MARK: - Thinking Block Boundary Tests

    func testToolInvocationEndResetsThinkingStateForNewBlock() async throws {
        // Given: A tool end event
        let event = ToolInvocationCompletedPlugin.Result(
            invocationId: "inv_thinking_reset",
            success: true,
            displayResult: "Done",
            durationMs: 100,
            details: nil
        )

        // When: Handling tool end
        coordinator.handleToolInvocationCompleted(event, context: mockContext)

        // Then: Thinking state should be reset for new block
        XCTAssertTrue(mockContext.resetThinkingForNewBlockCalled)
    }

    func testToolInvocationEndFinalizesThinkingBeforeReset() async throws {
        // Given: A tool end event
        let event = ToolInvocationCompletedPlugin.Result(
            invocationId: "inv_thinking_finalize",
            success: true,
            displayResult: "Done",
            durationMs: 100,
            details: nil
        )

        // When: Handling tool end
        coordinator.handleToolInvocationCompleted(event, context: mockContext)

        // Then: Thinking should be finalized and then reset
        XCTAssertTrue(mockContext.finalizeThinkingMessageIfNeededCalled)
        XCTAssertTrue(mockContext.resetThinkingForNewBlockCalled)
    }

}

// MARK: - Mock Context

/// Mock implementation of ToolInvocationContext for testing
@MainActor
final class MockToolInvocationContext: ToolInvocationContext {
    // MARK: - State
    var messages: [ChatMessage] = []
    let messageIndex = MessageIndex()
    var runningToolInvocationCount: Int = 0
    var currentTurnToolMessageIds: Set<UUID> = []
    var pendingUserInputRequest: UserInputRequest?
    var userInputAutoPresentationInvocationId: String?

    // MARK: - Tracking for Assertions
    var flushPendingTextUpdatesCalled = false
    var finalizeStreamingMessageCalled = false
    var visibleInvocationIds: Set<String> = []
    var enqueuedToolStarts: [UIUpdateQueue.ToolInvocationStartData] = []
    var enqueuedToolEnds: [UIUpdateQueue.ToolInvocationEndData] = []
    var resetThinkingForNewBlockCalled = false
    var finalizeThinkingMessageIfNeededCalled = false

    // MARK: - Protocol Methods

    func flushPendingTextUpdates() {
        flushPendingTextUpdatesCalled = true
    }

    func finalizeStreamingMessage() {
        finalizeStreamingMessageCalled = true
    }

    func makeToolInvocationVisible(_ invocationId: String) {
        visibleInvocationIds.insert(invocationId)
    }

    func enqueueToolInvocationStart(_ data: UIUpdateQueue.ToolInvocationStartData) {
        enqueuedToolStarts.append(data)
    }

    func enqueueToolInvocationEnd(_ data: UIUpdateQueue.ToolInvocationEndData) {
        enqueuedToolEnds.append(data)
    }

    func resetThinkingForNewBlock() {
        resetThinkingForNewBlockCalled = true
    }

    func finalizeThinkingMessageIfNeeded() {
        finalizeThinkingMessageIfNeededCalled = true
    }

    // MARK: - Logging
    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
    func showError(_ message: String) {}
}

// MARK: - Test Helper Extensions

/// Test-only initializer for concise start-event fixtures.
extension ToolInvocationStartedPlugin.Result {
    init(
        toolName: String,
        invocationId: String,
        arguments: [String: AnyCodable]?,
        formattedArguments: String,
        identity: ToolIdentity? = nil
    ) {
        // Parse formattedArguments back to arguments if arguments is nil
        var args = arguments
        if args == nil && !formattedArguments.isEmpty {
            if let data = formattedArguments.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String: AnyCodable].self, from: data) {
                args = parsed
            }
        }
        self.init(toolName: toolName, invocationId: invocationId, arguments: args, identity: identity)
    }
}

/// Test-only initializer for concise completion-event fixtures.
extension ToolInvocationCompletedPlugin.Result {
    init(invocationId: String, success: Bool, displayResult: String, durationMs: Int?, details: ToolInvocationCompletedPlugin.EventData.ToolResultDetails?) {
        self.init(
            invocationId: invocationId,
            toolName: "test_tool",
            isError: !success,
            content: displayResult,
            duration: durationMs,
            details: details,
            rawDetails: nil,
            identity: testToolIdentity()
        )
    }
}
