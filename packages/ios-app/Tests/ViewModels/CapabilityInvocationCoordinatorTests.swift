import XCTest
@testable import TronMobile

/// Tests for CapabilityInvocationCoordinator - handles capability start/end UI coordination
/// Uses TDD: Tests written first, then implementation follows
@MainActor
final class CapabilityInvocationCoordinatorTests: XCTestCase {

    var coordinator: CapabilityInvocationCoordinator!
    var mockContext: MockCapabilityInvocationContext!

    override func setUp() async throws {
        mockContext = MockCapabilityInvocationContext()
        coordinator = CapabilityInvocationCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - Tool Generating Tests

    func testToolGeneratingCreatesRunningChip() async throws {
        // Given: A tool generating event
        let result = CapabilityInvocationGeneratingPlugin.Result(
            modelToolName: "execute",
            invocationId: "gen_123",
            identity: CapabilityIdentity(modelToolName: "execute", contractId: "filesystem::write_file")
        )

        // When: Handling tool generating
        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        // Then: A capability invocation should be created with .generating status
        XCTAssertEqual(mockContext.messages.count, 1)
        XCTAssertEqual(mockContext.messages[0].role, .assistant)
        if case .capabilityInvocation(let invocation) = mockContext.messages[0].content {
            XCTAssertEqual(invocation.identity.modelToolName, "execute")
            XCTAssertEqual(invocation.identity.contractId, "filesystem::write_file")
            XCTAssertEqual(invocation.id, "gen_123")
            XCTAssertEqual(invocation.status, .generating)
            XCTAssertEqual(invocation.arguments, "")
        } else {
            XCTFail("Expected capability invocation content")
        }
    }

    func testToolGeneratingFinalizesThinkingMessage() async throws {
        let result = CapabilityInvocationGeneratingPlugin.Result(modelToolName: "Write", invocationId: "gen_think")

        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        XCTAssertTrue(mockContext.finalizeThinkingMessageIfNeededCalled)
    }

    func testToolGeneratingFlushesStreamingText() async throws {
        let result = CapabilityInvocationGeneratingPlugin.Result(modelToolName: "Write", invocationId: "gen_flush")

        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testToolGeneratingMakesToolVisible() async throws {
        let result = CapabilityInvocationGeneratingPlugin.Result(modelToolName: "Write", invocationId: "gen_vis")

        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        XCTAssertTrue(mockContext.visibleInvocationIds.contains("gen_vis"))
    }

    func testToolGeneratingEnqueuesToolStart() async throws {
        let result = CapabilityInvocationGeneratingPlugin.Result(modelToolName: "Write", invocationId: "gen_enq")

        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        XCTAssertEqual(mockContext.enqueuedToolStarts.count, 1)
        XCTAssertEqual(mockContext.enqueuedToolStarts[0].invocationId, "gen_enq")
        XCTAssertEqual(mockContext.enqueuedToolStarts[0].modelToolName, "Write")
    }

    func testToolGeneratingTracksCapabilityInvocation() async throws {
        let result = CapabilityInvocationGeneratingPlugin.Result(modelToolName: "Bash", invocationId: "gen_track")

        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations.count, 1)
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations[0].invocationId, "gen_track")
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations[0].modelToolName, "Bash")
    }

    func testToolGeneratingSkipsDuplicateChip() async throws {
        // Given: A tool message already exists
        let existing = ChatMessage(
            role: .assistant,
            content: .capabilityInvocation(testCapabilityInvocation(
                id: "dup_123",
                status: .running,
                identity: testCapabilityIdentity(modelToolName: "Write")
            ))
        )
        mockContext.messages.append(existing)

        // When: capability.invocation.generating arrives for same invocationId
        let result = CapabilityInvocationGeneratingPlugin.Result(modelToolName: "Write", invocationId: "dup_123")
        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        // Then: No duplicate message created
        XCTAssertEqual(mockContext.messages.count, 1)
    }

    func testToolGeneratingCreatesGeneratingChipForAskUserQuestion() async throws {
        let result = CapabilityInvocationGeneratingPlugin.Result(
            modelToolName: "execute",
            invocationId: "gen_ask",
            identity: testAskUserCapabilityIdentity()
        )

        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        // Should create a message with .generating status
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .askUserQuestion(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.invocationId, "gen_ask")
            XCTAssertEqual(data.status, .generating)
            XCTAssertTrue(data.params.questions.isEmpty)
        } else {
            XCTFail("Expected askUserQuestion content")
        }
        XCTAssertTrue(mockContext.visibleInvocationIds.contains("gen_ask"))
    }

    func testToolStartUpdatesGeneratingAskUserQuestionChip() async throws {
        // Given: capability.invocation.generating already created a .generating chip
        let askUserIdentity = testAskUserCapabilityIdentity()
        let genResult = CapabilityInvocationGeneratingPlugin.Result(
            modelToolName: "execute",
            invocationId: "gen_ask_update",
            identity: askUserIdentity
        )
        coordinator.handleCapabilityInvocationGenerating(genResult, context: mockContext)
        XCTAssertEqual(mockContext.messages.count, 1)

        // When: capability.invocation.started arrives with real params encoded in formattedArguments
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
        let event = CapabilityInvocationStartedPlugin.Result(
            modelToolName: "execute",
            invocationId: "gen_ask_update",
            arguments: nil,
            formattedArguments: paramsJson,
            identity: askUserIdentity
        )
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

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
        // Given: capability.invocation.generating already created a chip with empty arguments
        let genResult = CapabilityInvocationGeneratingPlugin.Result(modelToolName: "Write", invocationId: "gen_first")
        coordinator.handleCapabilityInvocationGenerating(genResult, context: mockContext)
        XCTAssertEqual(mockContext.messages.count, 1)

        // When: capability.invocation.started arrives for same invocationId with full arguments
        let event = CapabilityInvocationStartedPlugin.Result(
            modelToolName: "Write",
            invocationId: "gen_first",
            arguments: ["file_path": AnyCodable("/test.txt")],
            formattedArguments: "{\"file_path\":\"/test.txt\"}"
        )
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: No duplicate message (still just 1)
        XCTAssertEqual(mockContext.messages.count, 1)
        // Then: Tool is still visible
        XCTAssertTrue(mockContext.visibleInvocationIds.contains("gen_first"))
        // Then: Arguments are updated from empty to full
        if case .capabilityInvocation(let invocation) = mockContext.messages[0].content {
            XCTAssertFalse(invocation.arguments.isEmpty, "Arguments should be updated from empty")
            XCTAssertTrue(invocation.arguments.contains("file_path"), "Arguments should contain the file_path")
        } else {
            XCTFail("Expected capability invocation content")
        }
        // Then: currentToolMessages is updated
        XCTAssertEqual(mockContext.currentToolMessages.count, 1)
        // Then: currentTurnCapabilityInvocations arguments are updated
        XCTAssertTrue(mockContext.currentTurnCapabilityInvocations[0].arguments.contains("file_path"))
    }

    func testToolEndUpdatesGeneratingChip() async throws {
        // Given: capability.invocation.generating created a chip
        let genResult = CapabilityInvocationGeneratingPlugin.Result(modelToolName: "Write", invocationId: "gen_end")
        coordinator.handleCapabilityInvocationGenerating(genResult, context: mockContext)
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations.count, 1)

        // When: capability.invocation.completed arrives
        let endEvent = CapabilityInvocationCompletedPlugin.Result(
            invocationId: "gen_end",
            success: true,
            displayResult: "File written",
            durationMs: 150,
            details: nil
        )
        coordinator.handleCapabilityInvocationCompleted(endEvent, context: mockContext)

        // Then: Capability invocation record is updated
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations[0].result, "File written")
        // Then: Capability end is enqueued
        XCTAssertEqual(mockContext.enqueuedToolEnds.count, 1)
    }

    func testMultipleToolGeneratingEvents() async throws {
        // When: Two capability.invocation.generating events arrive
        coordinator.handleCapabilityInvocationGenerating(
            CapabilityInvocationGeneratingPlugin.Result(
                modelToolName: "execute",
                invocationId: "tc1",
                identity: CapabilityIdentity(modelToolName: "execute", contractId: "filesystem::write_file")
            ),
            context: mockContext
        )
        coordinator.handleCapabilityInvocationGenerating(
            CapabilityInvocationGeneratingPlugin.Result(
                modelToolName: "execute",
                invocationId: "tc2",
                identity: CapabilityIdentity(modelToolName: "execute", contractId: "process::run")
            ),
            context: mockContext
        )

        // Then: Two messages created
        XCTAssertEqual(mockContext.messages.count, 2)
        // Then: Both have .generating status
        if case .capabilityInvocation(let invocation1) = mockContext.messages[0].content {
            XCTAssertEqual(invocation1.status, .generating)
            XCTAssertEqual(invocation1.identity.modelToolName, "execute")
            XCTAssertEqual(invocation1.identity.contractId, "filesystem::write_file")
        } else { XCTFail("Expected capability invocation content") }
        if case .capabilityInvocation(let invocation2) = mockContext.messages[1].content {
            XCTAssertEqual(invocation2.status, .generating)
            XCTAssertEqual(invocation2.identity.modelToolName, "execute")
            XCTAssertEqual(invocation2.identity.contractId, "process::run")
        } else { XCTFail("Expected capability invocation content") }
        // Then: Two enqueued capability starts
        XCTAssertEqual(mockContext.enqueuedToolStarts.count, 2)
        XCTAssertEqual(mockContext.enqueuedToolStarts[0].invocationId, "tc1")
        XCTAssertEqual(mockContext.enqueuedToolStarts[1].invocationId, "tc2")
    }

    // MARK: - Tool Start Tests

    func testToolStartCreatesToolMessage() async throws {
        // Given: A capability start event
        let event = CapabilityInvocationStartedPlugin.Result(
            modelToolName: "execute",
            invocationId: "tool_123",
            arguments: nil,
            formattedArguments: "{\"command\": \"ls -la\"}",
            identity: CapabilityIdentity(modelToolName: "execute", contractId: "process::run")
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: A tool message should be created
        XCTAssertEqual(mockContext.messages.count, 1)
        XCTAssertEqual(mockContext.messages[0].role, .assistant)
        if case .capabilityInvocation(let invocation) = mockContext.messages[0].content {
            XCTAssertEqual(invocation.identity.modelToolName, "execute")
            XCTAssertEqual(invocation.identity.contractId, "process::run")
            XCTAssertEqual(invocation.id, "tool_123")
            XCTAssertEqual(invocation.status, .running)
        } else {
            XCTFail("Expected capability invocation content")
        }
    }

    func testToolStartFlushesStreamingTextFirst() async throws {
        // Given: A capability start event
        let event = CapabilityInvocationStartedPlugin.Result(
            modelToolName: "Read",
            invocationId: "tool_456",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Streaming text should be flushed first
        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testToolStartFinalizesThinkingMessage() async throws {
        // Given: A capability start event
        let event = CapabilityInvocationStartedPlugin.Result(
            modelToolName: "Read",
            invocationId: "tool_thinking_start",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Thinking should be finalized
        XCTAssertTrue(mockContext.finalizeThinkingMessageIfNeededCalled)
    }

    func testToolStartTracksCapabilityInvocation() async throws {
        // Given: A capability start event
        let event = CapabilityInvocationStartedPlugin.Result(
            modelToolName: "Grep",
            invocationId: "tool_789",
            arguments: nil,
            formattedArguments: "{\"pattern\": \"TODO\"}"
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Capability invocation should be tracked
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations.count, 1)
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations[0].invocationId, "tool_789")
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations[0].modelToolName, "Grep")
    }

    func testToolStartMakesToolVisible() async throws {
        // Given: A capability start event
        let event = CapabilityInvocationStartedPlugin.Result(
            modelToolName: "Edit",
            invocationId: "tool_visible",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Tool should be made visible for animation
        XCTAssertTrue(mockContext.visibleInvocationIds.contains("tool_visible"))
    }

    func testToolStartEnqueuesForUIUpdateQueue() async throws {
        // Given: A capability start event
        let event = CapabilityInvocationStartedPlugin.Result(
            modelToolName: "Write",
            invocationId: "tool_queue",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Should be enqueued for ordered processing
        XCTAssertEqual(mockContext.enqueuedToolStarts.count, 1)
        XCTAssertEqual(mockContext.enqueuedToolStarts[0].invocationId, "tool_queue")
    }

    // MARK: - AskUserQuestion Tool Tests

    func testAskUserQuestionToolStart() async throws {
        // Given: An AskUserQuestion capability start with params encoded in formattedArguments
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
        let event = CapabilityInvocationStartedPlugin.Result(
            modelToolName: "execute",
            invocationId: "ask_123",
            arguments: nil,
            formattedArguments: paramsJson,
            identity: testAskUserCapabilityIdentity()
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Should create AskUserQuestion message
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .askUserQuestion(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.invocationId, "ask_123")
            XCTAssertEqual(data.status, .pending)
            XCTAssertEqual(data.params.questions.count, 1)
        } else {
            XCTFail("Expected askUserQuestion content")
        }

        // Then: Should mark calledInTurn
        XCTAssertTrue(mockContext.askUserQuestionCalledInTurn)
    }

    func testAskUserQuestionToolStartFallsBackOnParseFailure() async throws {
        // Given: An AskUserQuestion capability start with invalid JSON (parse will fail)
        let event = CapabilityInvocationStartedPlugin.Result(
            modelToolName: "execute",
            invocationId: "ask_fail",
            arguments: nil,
            formattedArguments: "invalid json",
            identity: testAskUserCapabilityIdentity()
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Should render a capability error instead of inferring an old-name fallback
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .capabilityInvocation(let invocation) = mockContext.messages[0].content {
            XCTAssertEqual(invocation.identity.contractId, "agent::ask_user")
            XCTAssertEqual(invocation.status, .error)
            XCTAssertEqual(invocation.result, "Unable to parse interaction payload.")
        } else {
            XCTFail("Expected capability invocation content for malformed request")
        }
    }

    // MARK: - Tool End Tests

    func testToolEndEnqueuesForProcessing() async throws {
        // Given: A capability end event
        let event = CapabilityInvocationCompletedPlugin.Result(
            invocationId: "capability.invocation.completed_123",
            success: true,
            displayResult: "Success!",
            durationMs: 150,
            details: nil
        )

        // When: Handling capability end
        coordinator.handleCapabilityInvocationCompleted(event, context: mockContext)

        // Then: Should enqueue for ordered processing
        XCTAssertEqual(mockContext.enqueuedToolEnds.count, 1)
        XCTAssertEqual(mockContext.enqueuedToolEnds[0].invocationId, "capability.invocation.completed_123")
        XCTAssertTrue(mockContext.enqueuedToolEnds[0].success)
    }

    func testToolEndUpdatesCapabilityInvocationRecord() async throws {
        // Given: A tracked capability invocation
        mockContext.currentTurnCapabilityInvocations.append(CapabilityInvocationRecord(
            invocationId: "tool_track_123",
            modelToolName: "Bash",
            arguments: "{}"
        ))

        // Given: A capability end event
        let event = CapabilityInvocationCompletedPlugin.Result(
            invocationId: "tool_track_123",
            success: false,
            displayResult: "Command failed",
            durationMs: 50,
            details: nil
        )

        // When: Handling capability end
        coordinator.handleCapabilityInvocationCompleted(event, context: mockContext)

        // Then: Capability invocation record should be updated
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations[0].result, "Command failed")
        XCTAssertTrue(mockContext.currentTurnCapabilityInvocations[0].isError)
    }

    func testAskUserQuestionToolEndOpensSheet() async throws {
        // Given: An AskUserQuestion message exists
        let askData = AskUserQuestionToolData(
            invocationId: "ask_sheet_123",
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

        // Given: Capability end arrives
        let event = CapabilityInvocationCompletedPlugin.Result(
            invocationId: "ask_sheet_123",
            success: true,
            displayResult: "",
            durationMs: 100,
            details: nil
        )

        // When: Handling capability end
        coordinator.handleCapabilityInvocationCompleted(event, context: mockContext)

        // Then: Sheet should be opened
        XCTAssertTrue(mockContext.askUserQuestionSheetOpened)
    }

    // MARK: - Thinking Block Boundary Tests

    func testToolEndResetsThinkingStateForNewBlock() async throws {
        // Given: A capability end event
        let event = CapabilityInvocationCompletedPlugin.Result(
            invocationId: "tool_thinking_reset",
            success: true,
            displayResult: "Done",
            durationMs: 100,
            details: nil
        )

        // When: Handling capability end
        coordinator.handleCapabilityInvocationCompleted(event, context: mockContext)

        // Then: Thinking state should be reset for new block
        XCTAssertTrue(mockContext.resetThinkingForNewBlockCalled)
    }

    func testToolEndFinalizesThinkingBeforeReset() async throws {
        // Given: A capability end event
        let event = CapabilityInvocationCompletedPlugin.Result(
            invocationId: "tool_thinking_finalize",
            success: true,
            displayResult: "Done",
            durationMs: 100,
            details: nil
        )

        // When: Handling capability end
        coordinator.handleCapabilityInvocationCompleted(event, context: mockContext)

        // Then: Thinking should be finalized and then reset
        XCTAssertTrue(mockContext.finalizeThinkingMessageIfNeededCalled)
        XCTAssertTrue(mockContext.resetThinkingForNewBlockCalled)
    }

    func testAskUserQuestionToolEndAlsoResetsThinkingState() async throws {
        // Given: An AskUserQuestion message exists
        let askData = AskUserQuestionToolData(
            invocationId: "ask_thinking_reset",
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

        // Given: Capability end arrives
        let event = CapabilityInvocationCompletedPlugin.Result(
            invocationId: "ask_thinking_reset",
            success: true,
            displayResult: "",
            durationMs: 100,
            details: nil
        )

        // When: Handling capability end (AskUserQuestion returns early, but should still reset)
        coordinator.handleCapabilityInvocationCompleted(event, context: mockContext)

        // Then: Thinking state should still be reset (called at start of handleCapabilityInvocationCompleted)
        XCTAssertTrue(mockContext.resetThinkingForNewBlockCalled)
    }

    func testToolEndDoesNotEnqueueForAskUserQuestion() async throws {
        // Given: An AskUserQuestion message exists
        let askData = AskUserQuestionToolData(
            invocationId: "ask_no_enqueue",
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

        // Given: Capability end arrives
        let event = CapabilityInvocationCompletedPlugin.Result(
            invocationId: "ask_no_enqueue",
            success: true,
            displayResult: "",
            durationMs: 100,
            details: nil
        )

        // When: Handling capability end
        coordinator.handleCapabilityInvocationCompleted(event, context: mockContext)

        // Then: Should NOT enqueue (AskUserQuestion returns early)
        XCTAssertEqual(mockContext.enqueuedToolEnds.count, 0)
    }
}

// MARK: - Mock Context

/// Mock implementation of CapabilityInvocationContext for testing
@MainActor
final class MockCapabilityInvocationContext: CapabilityInvocationContext {
    // MARK: - State
    var messages: [ChatMessage] = []
    let messageIndex = MessageIndex()
    var runningToolCount: Int = 0
    var currentToolMessages: [UUID: ChatMessage] = [:]
    var currentTurnCapabilityInvocations: [CapabilityInvocationRecord] = []

    // MARK: - State Objects
    var askUserQuestionCalledInTurn: Bool = false

    // MARK: - Tracking for Assertions
    var flushPendingTextUpdatesCalled = false
    var finalizeStreamingMessageCalled = false
    var visibleInvocationIds: Set<String> = []
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

    func makeCapabilityInvocationVisible(_ invocationId: String) {
        visibleInvocationIds.insert(invocationId)
    }

    func enqueueCapabilityInvocationStart(_ data: UIUpdateQueue.ToolStartData) {
        enqueuedToolStarts.append(data)
    }

    func enqueueToolEnd(_ data: UIUpdateQueue.ToolEndData) {
        enqueuedToolEnds.append(data)
    }

    func openAskUserQuestionSheet(for data: AskUserQuestionToolData) {
        askUserQuestionSheetOpened = true
        openedAskUserQuestionData = data
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
extension CapabilityInvocationStartedPlugin.Result {
    init(
        modelToolName: String,
        invocationId: String,
        arguments: [String: AnyCodable]?,
        formattedArguments: String,
        identity: CapabilityIdentity? = nil
    ) {
        // Parse formattedArguments back to arguments if arguments is nil
        var args = arguments
        if args == nil && !formattedArguments.isEmpty {
            if let data = formattedArguments.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String: AnyCodable].self, from: data) {
                args = parsed
            }
        }
        self.init(modelToolName: modelToolName, invocationId: invocationId, arguments: args, identity: identity)
    }
}

/// Test-only initializer matching the historical ToolEndEvent constructor.
extension CapabilityInvocationCompletedPlugin.Result {
    init(invocationId: String, success: Bool, displayResult: String, durationMs: Int?, details: CapabilityInvocationCompletedPlugin.EventData.ToolDetails?) {
        self.init(
            invocationId: invocationId,
            modelToolName: nil,
            success: success,
            output: success ? displayResult : nil,
            error: success ? nil : displayResult,
            duration: durationMs,
            details: details,
            rawDetails: nil,
            identity: testCapabilityIdentity()
        )
    }
}
