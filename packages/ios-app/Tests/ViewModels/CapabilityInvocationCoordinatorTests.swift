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

    // MARK: - Capability Generating Tests

    func testCapabilityInvocationGeneratingCreatesRunningChip() async throws {
        // Given: A capability generating event
        let result = CapabilityInvocationGeneratingPlugin.Result(
            modelPrimitiveName: "execute",
            invocationId: "gen_123",
            identity: CapabilityIdentity(modelPrimitiveName: "execute", contractId: "filesystem::write_file")
        )

        // When: Handling capability generating
        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        // Then: A capability invocation should be created with .generating status
        XCTAssertEqual(mockContext.messages.count, 1)
        XCTAssertEqual(mockContext.messages[0].role, .assistant)
        if case .capabilityInvocation(let invocation) = mockContext.messages[0].content {
            XCTAssertEqual(invocation.identity.modelPrimitiveName, "execute")
            XCTAssertEqual(invocation.identity.contractId, "filesystem::write_file")
            XCTAssertEqual(invocation.id, "gen_123")
            XCTAssertEqual(invocation.status, .generating)
            XCTAssertEqual(invocation.arguments, "")
        } else {
            XCTFail("Expected capability invocation content")
        }
    }

    func testCapabilityInvocationGeneratingFinalizesThinkingMessage() async throws {
        let result = CapabilityInvocationGeneratingPlugin.Result(modelPrimitiveName: "execute", invocationId: "gen_think")

        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        XCTAssertTrue(mockContext.finalizeThinkingMessageIfNeededCalled)
    }

    func testCapabilityInvocationGeneratingFlushesStreamingText() async throws {
        let result = CapabilityInvocationGeneratingPlugin.Result(modelPrimitiveName: "execute", invocationId: "gen_flush")

        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testCapabilityInvocationGeneratingMakesCapabilityVisible() async throws {
        let result = CapabilityInvocationGeneratingPlugin.Result(modelPrimitiveName: "execute", invocationId: "gen_vis")

        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        XCTAssertTrue(mockContext.visibleInvocationIds.contains("gen_vis"))
    }

    func testCapabilityInvocationGeneratingEnqueuesCapabilityInvocationStart() async throws {
        let result = CapabilityInvocationGeneratingPlugin.Result(modelPrimitiveName: "execute", invocationId: "gen_enq")

        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        XCTAssertEqual(mockContext.enqueuedCapabilityStarts.count, 1)
        XCTAssertEqual(mockContext.enqueuedCapabilityStarts[0].invocationId, "gen_enq")
        XCTAssertEqual(mockContext.enqueuedCapabilityStarts[0].modelPrimitiveName, "execute")
    }

    func testCapabilityInvocationGeneratingTracksCapabilityInvocation() async throws {
        let result = CapabilityInvocationGeneratingPlugin.Result(modelPrimitiveName: "execute", invocationId: "gen_track")

        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations.count, 1)
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations[0].invocationId, "gen_track")
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations[0].modelPrimitiveName, "execute")
    }

    func testCapabilityInvocationGeneratingSkipsDuplicateChip() async throws {
        // Given: A capability message already exists
        let existing = ChatMessage(
            role: .assistant,
            content: .capabilityInvocation(testCapabilityInvocation(
                id: "dup_123",
                status: .running,
                identity: testCapabilityIdentity(modelPrimitiveName: "execute")
            ))
        )
        mockContext.messages.append(existing)

        // When: capability.invocation.generating arrives for same invocationId
        let result = CapabilityInvocationGeneratingPlugin.Result(modelPrimitiveName: "execute", invocationId: "dup_123")
        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        // Then: No duplicate message created
        XCTAssertEqual(mockContext.messages.count, 1)
    }

    func testCapabilityInvocationGeneratingCreatesGeneratingChipForUserInteraction() async throws {
        let result = CapabilityInvocationGeneratingPlugin.Result(
            modelPrimitiveName: "execute",
            invocationId: "gen_ask",
            identity: testUserInteractionCapabilityIdentity()
        )

        coordinator.handleCapabilityInvocationGenerating(result, context: mockContext)

        // Should create a message with .generating status
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .userInteraction(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.invocationId, "gen_ask")
            XCTAssertEqual(data.status, .generating)
            XCTAssertTrue(data.params.questions.isEmpty)
        } else {
            XCTFail("Expected userInteraction content")
        }
        XCTAssertTrue(mockContext.visibleInvocationIds.contains("gen_ask"))
    }

    func testCapabilityInvocationStartUpdatesGeneratingUserInteractionChip() async throws {
        // Given: capability.invocation.generating already created a .generating chip
        let userInteractionIdentity = testUserInteractionCapabilityIdentity()
        let genResult = CapabilityInvocationGeneratingPlugin.Result(
            modelPrimitiveName: "execute",
            invocationId: "gen_ask_update",
            identity: userInteractionIdentity
        )
        coordinator.handleCapabilityInvocationGenerating(genResult, context: mockContext)
        XCTAssertEqual(mockContext.messages.count, 1)

        // When: capability.invocation.started arrives with real params encoded in formattedArguments
        let params = UserInteractionParams(
            questions: [
                UserInteraction(
                    id: "q1",
                    question: "Pick one?",
                    options: [
                        UserInteractionOption(label: "A", value: nil, description: nil),
                        UserInteractionOption(label: "B", value: nil, description: nil)
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
            modelPrimitiveName: "execute",
            invocationId: "gen_ask_update",
            arguments: nil,
            formattedArguments: paramsJson,
            identity: userInteractionIdentity
        )
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: No duplicate message (still just 1)
        XCTAssertEqual(mockContext.messages.count, 1)
        // Then: Status updated from .generating to .pending with real params
        if case .userInteraction(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.status, .pending)
            XCTAssertEqual(data.params.questions.count, 1)
            XCTAssertEqual(data.params.questions[0].question, "Pick one?")
        } else {
            XCTFail("Expected userInteraction content")
        }
        // Then: calledInTurn is set
        XCTAssertTrue(mockContext.userInteractionCalledInTurn)
    }

    func testCapabilityInvocationStartUpdatesDuplicateFromGenerating() async throws {
        // Given: capability.invocation.generating already created a chip with empty arguments
        let genResult = CapabilityInvocationGeneratingPlugin.Result(modelPrimitiveName: "execute", invocationId: "gen_first")
        coordinator.handleCapabilityInvocationGenerating(genResult, context: mockContext)
        XCTAssertEqual(mockContext.messages.count, 1)

        // When: capability.invocation.started arrives for same invocationId with full arguments
        let event = CapabilityInvocationStartedPlugin.Result(
            modelPrimitiveName: "execute",
            invocationId: "gen_first",
            arguments: ["file_path": AnyCodable("/test.txt")],
            formattedArguments: "{\"file_path\":\"/test.txt\"}"
        )
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: No duplicate message (still just 1)
        XCTAssertEqual(mockContext.messages.count, 1)
        // Then: Capability is still visible
        XCTAssertTrue(mockContext.visibleInvocationIds.contains("gen_first"))
        // Then: Arguments are updated from empty to full
        if case .capabilityInvocation(let invocation) = mockContext.messages[0].content {
            XCTAssertFalse(invocation.arguments.isEmpty, "Arguments should be updated from empty")
            XCTAssertTrue(invocation.arguments.contains("file_path"), "Arguments should contain the file_path")
        } else {
            XCTFail("Expected capability invocation content")
        }
        // Then: currentCapabilityInvocationMessages is updated
        XCTAssertEqual(mockContext.currentCapabilityInvocationMessages.count, 1)
        // Then: currentTurnCapabilityInvocations arguments are updated
        XCTAssertTrue(mockContext.currentTurnCapabilityInvocations[0].arguments.contains("file_path"))
    }

    func testCapabilityInvocationEndUpdatesGeneratingChip() async throws {
        // Given: capability.invocation.generating created a chip
        let genResult = CapabilityInvocationGeneratingPlugin.Result(modelPrimitiveName: "execute", invocationId: "gen_end")
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
        XCTAssertEqual(mockContext.enqueuedCapabilityEnds.count, 1)
    }

    func testMultipleCapabilityGeneratingEvents() async throws {
        // When: Two capability.invocation.generating events arrive
        coordinator.handleCapabilityInvocationGenerating(
            CapabilityInvocationGeneratingPlugin.Result(
                modelPrimitiveName: "execute",
                invocationId: "tc1",
                identity: CapabilityIdentity(modelPrimitiveName: "execute", contractId: "filesystem::write_file")
            ),
            context: mockContext
        )
        coordinator.handleCapabilityInvocationGenerating(
            CapabilityInvocationGeneratingPlugin.Result(
                modelPrimitiveName: "execute",
                invocationId: "tc2",
                identity: CapabilityIdentity(modelPrimitiveName: "execute", contractId: "process::run")
            ),
            context: mockContext
        )

        // Then: Two messages created
        XCTAssertEqual(mockContext.messages.count, 2)
        // Then: Both have .generating status
        if case .capabilityInvocation(let invocation1) = mockContext.messages[0].content {
            XCTAssertEqual(invocation1.status, .generating)
            XCTAssertEqual(invocation1.identity.modelPrimitiveName, "execute")
            XCTAssertEqual(invocation1.identity.contractId, "filesystem::write_file")
        } else { XCTFail("Expected capability invocation content") }
        if case .capabilityInvocation(let invocation2) = mockContext.messages[1].content {
            XCTAssertEqual(invocation2.status, .generating)
            XCTAssertEqual(invocation2.identity.modelPrimitiveName, "execute")
            XCTAssertEqual(invocation2.identity.contractId, "process::run")
        } else { XCTFail("Expected capability invocation content") }
        // Then: Two enqueued capability starts
        XCTAssertEqual(mockContext.enqueuedCapabilityStarts.count, 2)
        XCTAssertEqual(mockContext.enqueuedCapabilityStarts[0].invocationId, "tc1")
        XCTAssertEqual(mockContext.enqueuedCapabilityStarts[1].invocationId, "tc2")
    }

    // MARK: - Capability Start Tests

    func testCapabilityInvocationStartCreatesCapabilityMessage() async throws {
        // Given: A capability start event
        let event = CapabilityInvocationStartedPlugin.Result(
            modelPrimitiveName: "execute",
            invocationId: "inv_123",
            arguments: nil,
            formattedArguments: "{\"command\": \"ls -la\"}",
            identity: CapabilityIdentity(modelPrimitiveName: "execute", contractId: "process::run")
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: A capability message should be created
        XCTAssertEqual(mockContext.messages.count, 1)
        XCTAssertEqual(mockContext.messages[0].role, .assistant)
        if case .capabilityInvocation(let invocation) = mockContext.messages[0].content {
            XCTAssertEqual(invocation.identity.modelPrimitiveName, "execute")
            XCTAssertEqual(invocation.identity.contractId, "process::run")
            XCTAssertEqual(invocation.id, "inv_123")
            XCTAssertEqual(invocation.status, .running)
        } else {
            XCTFail("Expected capability invocation content")
        }
    }

    func testCapabilityInvocationStartFlushesStreamingTextFirst() async throws {
        // Given: A capability start event
        let event = CapabilityInvocationStartedPlugin.Result(
            modelPrimitiveName: "execute",
            invocationId: "inv_456",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Streaming text should be flushed first
        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testCapabilityInvocationStartFinalizesThinkingMessage() async throws {
        // Given: A capability start event
        let event = CapabilityInvocationStartedPlugin.Result(
            modelPrimitiveName: "execute",
            invocationId: "inv_thinking_start",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Thinking should be finalized
        XCTAssertTrue(mockContext.finalizeThinkingMessageIfNeededCalled)
    }

    func testCapabilityInvocationStartTracksCapabilityInvocation() async throws {
        // Given: A capability start event
        let event = CapabilityInvocationStartedPlugin.Result(
            modelPrimitiveName: "execute",
            invocationId: "inv_789",
            arguments: nil,
            formattedArguments: "{\"contractId\":\"filesystem::search_text\",\"payload\":{\"pattern\":\"TODO\"}}",
            identity: CapabilityIdentity(modelPrimitiveName: "execute", contractId: "filesystem::search_text")
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Capability invocation should be tracked
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations.count, 1)
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations[0].invocationId, "inv_789")
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations[0].modelPrimitiveName, "execute")
        XCTAssertEqual(mockContext.currentTurnCapabilityInvocations[0].identity.contractId, "filesystem::search_text")
    }

    func testCapabilityInvocationStartMakesCapabilityVisible() async throws {
        // Given: A capability start event
        let event = CapabilityInvocationStartedPlugin.Result(
            modelPrimitiveName: "execute",
            invocationId: "inv_visible",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Capability should be made visible for animation
        XCTAssertTrue(mockContext.visibleInvocationIds.contains("inv_visible"))
    }

    func testCapabilityInvocationStartEnqueuesForUIUpdateQueue() async throws {
        // Given: A capability start event
        let event = CapabilityInvocationStartedPlugin.Result(
            modelPrimitiveName: "execute",
            invocationId: "inv_queue",
            arguments: nil,
            formattedArguments: "{}"
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Should be enqueued for ordered processing
        XCTAssertEqual(mockContext.enqueuedCapabilityStarts.count, 1)
        XCTAssertEqual(mockContext.enqueuedCapabilityStarts[0].invocationId, "inv_queue")
    }

    // MARK: - UserInteraction Capability Tests

    func testUserInteractionCapabilityInvocationStart() async throws {
        // Given: An UserInteraction capability start with params encoded in formattedArguments
        let params = UserInteractionParams(
            questions: [
                UserInteraction(
                    id: "q1",
                    question: "Pick one?",
                    options: [
                        UserInteractionOption(label: "A", value: nil, description: "Option A"),
                        UserInteractionOption(label: "B", value: nil, description: "Option B")
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
            modelPrimitiveName: "execute",
            invocationId: "ask_123",
            arguments: nil,
            formattedArguments: paramsJson,
            identity: testUserInteractionCapabilityIdentity()
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Should create UserInteraction message
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .userInteraction(let data) = mockContext.messages[0].content {
            XCTAssertEqual(data.invocationId, "ask_123")
            XCTAssertEqual(data.status, .pending)
            XCTAssertEqual(data.params.questions.count, 1)
        } else {
            XCTFail("Expected userInteraction content")
        }

        // Then: Should mark calledInTurn
        XCTAssertTrue(mockContext.userInteractionCalledInTurn)
    }

    func testUserInteractionCapabilityInvocationStartRendersErrorOnParseFailure() async throws {
        // Given: An UserInteraction capability start with invalid JSON (parse will fail)
        let event = CapabilityInvocationStartedPlugin.Result(
            modelPrimitiveName: "execute",
            invocationId: "ask_fail",
            arguments: nil,
            formattedArguments: "invalid json",
            identity: testUserInteractionCapabilityIdentity()
        )

        // When: Handling capability start
        coordinator.handleCapabilityInvocationStarted(event, context: mockContext)

        // Then: Should render a capability error instead of inferring an old-name identity
        XCTAssertEqual(mockContext.messages.count, 1)
        if case .capabilityInvocation(let invocation) = mockContext.messages[0].content {
            XCTAssertEqual(invocation.identity.contractId, "agent::ask_user")
            XCTAssertEqual(invocation.status, .error)
            XCTAssertEqual(invocation.result, "Unable to parse interaction payload.")
        } else {
            XCTFail("Expected capability invocation content for malformed request")
        }
    }

    // MARK: - Capability End Tests

    func testCapabilityInvocationEndEnqueuesForProcessing() async throws {
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
        XCTAssertEqual(mockContext.enqueuedCapabilityEnds.count, 1)
        XCTAssertEqual(mockContext.enqueuedCapabilityEnds[0].invocationId, "capability.invocation.completed_123")
        XCTAssertTrue(mockContext.enqueuedCapabilityEnds[0].success)
    }

    func testCapabilityInvocationEndUpdatesCapabilityInvocationRecord() async throws {
        // Given: A tracked capability invocation
        mockContext.currentTurnCapabilityInvocations.append(CapabilityInvocationRecord(
            invocationId: "inv_track_123",
            modelPrimitiveName: "execute",
            arguments: "{}"
        ))

        // Given: A capability end event
        let event = CapabilityInvocationCompletedPlugin.Result(
            invocationId: "inv_track_123",
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

    func testUserInteractionCapabilityInvocationEndOpensSheet() async throws {
        // Given: An UserInteraction message exists
        let askData = UserInteractionInvocationData(
            invocationId: "ask_sheet_123",
            params: UserInteractionParams(
                questions: [
                    UserInteraction(
                        id: "q1",
                        question: "Pick?",
                        options: [
                            UserInteractionOption(label: "A", value: nil, description: nil)
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
            content: .userInteraction(askData)
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
        XCTAssertTrue(mockContext.userInteractionSheetOpened)
    }

    // MARK: - Thinking Block Boundary Tests

    func testCapabilityInvocationEndResetsThinkingStateForNewBlock() async throws {
        // Given: A capability end event
        let event = CapabilityInvocationCompletedPlugin.Result(
            invocationId: "inv_thinking_reset",
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

    func testCapabilityInvocationEndFinalizesThinkingBeforeReset() async throws {
        // Given: A capability end event
        let event = CapabilityInvocationCompletedPlugin.Result(
            invocationId: "inv_thinking_finalize",
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

    func testUserInteractionCapabilityInvocationEndAlsoResetsThinkingState() async throws {
        // Given: An UserInteraction message exists
        let askData = UserInteractionInvocationData(
            invocationId: "ask_thinking_reset",
            params: UserInteractionParams(
                questions: [
                    UserInteraction(
                        id: "q1",
                        question: "Pick?",
                        options: [
                            UserInteractionOption(label: "A", value: nil, description: nil)
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
            content: .userInteraction(askData)
        ))

        // Given: Capability end arrives
        let event = CapabilityInvocationCompletedPlugin.Result(
            invocationId: "ask_thinking_reset",
            success: true,
            displayResult: "",
            durationMs: 100,
            details: nil
        )

        // When: Handling capability end (UserInteraction returns early, but should still reset)
        coordinator.handleCapabilityInvocationCompleted(event, context: mockContext)

        // Then: Thinking state should still be reset (called at start of handleCapabilityInvocationCompleted)
        XCTAssertTrue(mockContext.resetThinkingForNewBlockCalled)
    }

    func testCapabilityInvocationEndDoesNotEnqueueForUserInteraction() async throws {
        // Given: An UserInteraction message exists
        let askData = UserInteractionInvocationData(
            invocationId: "ask_no_enqueue",
            params: UserInteractionParams(
                questions: [
                    UserInteraction(
                        id: "q1",
                        question: "Pick?",
                        options: [
                            UserInteractionOption(label: "A", value: nil, description: nil)
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
            content: .userInteraction(askData)
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

        // Then: Should NOT enqueue (UserInteraction returns early)
        XCTAssertEqual(mockContext.enqueuedCapabilityEnds.count, 0)
    }
}

// MARK: - Mock Context

/// Mock implementation of CapabilityInvocationContext for testing
@MainActor
final class MockCapabilityInvocationContext: CapabilityInvocationContext {
    // MARK: - State
    var messages: [ChatMessage] = []
    let messageIndex = MessageIndex()
    var runningCapabilityInvocationCount: Int = 0
    var currentCapabilityInvocationMessages: [UUID: ChatMessage] = [:]
    var currentTurnCapabilityInvocations: [CapabilityInvocationRecord] = []

    // MARK: - State Objects
    var userInteractionCalledInTurn: Bool = false

    // MARK: - Tracking for Assertions
    var flushPendingTextUpdatesCalled = false
    var finalizeStreamingMessageCalled = false
    var visibleInvocationIds: Set<String> = []
    var enqueuedCapabilityStarts: [UIUpdateQueue.CapabilityInvocationStartData] = []
    var enqueuedCapabilityEnds: [UIUpdateQueue.CapabilityInvocationEndData] = []
    var userInteractionSheetOpened = false
    var openedUserInteractionData: UserInteractionInvocationData?
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

    func enqueueCapabilityInvocationStart(_ data: UIUpdateQueue.CapabilityInvocationStartData) {
        enqueuedCapabilityStarts.append(data)
    }

    func enqueueCapabilityInvocationEnd(_ data: UIUpdateQueue.CapabilityInvocationEndData) {
        enqueuedCapabilityEnds.append(data)
    }

    func openUserInteractionSheet(for data: UserInteractionInvocationData) {
        userInteractionSheetOpened = true
        openedUserInteractionData = data
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

/// Test-only initializer matching the historical CapabilityInvocationStartEvent constructor.
extension CapabilityInvocationStartedPlugin.Result {
    init(
        modelPrimitiveName: String,
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
        self.init(modelPrimitiveName: modelPrimitiveName, invocationId: invocationId, arguments: args, identity: identity)
    }
}

/// Test-only initializer matching the historical CapabilityInvocationEndEvent constructor.
extension CapabilityInvocationCompletedPlugin.Result {
    init(invocationId: String, success: Bool, displayResult: String, durationMs: Int?, details: CapabilityInvocationCompletedPlugin.EventData.CapabilityResultDetails?) {
        self.init(
            invocationId: invocationId,
            modelPrimitiveName: nil,
            isError: !success,
            content: displayResult,
            duration: durationMs,
            details: details,
            rawDetails: nil,
            identity: testCapabilityIdentity()
        )
    }
}
