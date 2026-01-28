import XCTest
@testable import TronMobile

/// Tests for ChatViewModel.findMessageId(for:) method
/// This method is used by deep linking to find the message UUID for a scroll target
@MainActor
final class ChatViewModelFindMessageTests: XCTestCase {

    var viewModel: ChatViewModel!

    override func setUp() async throws {
        // Create a minimal ChatViewModel for testing
        // Note: We don't need a real RPC client for these tests since we're only
        // testing the findMessageId method which works on local messages array
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        viewModel = ChatViewModel(rpcClient: rpcClient, sessionId: "test-session")
    }

    override func tearDown() async throws {
        viewModel = nil
    }

    // MARK: - Tool Call Tests

    func testFindMessageIdForToolCallInToolUse() {
        // Given: A message with toolUse content
        let messageId = UUID()
        let message = ChatMessage(
            id: messageId,
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: "NotifyApp",
                toolCallId: "toolu_abc",
                arguments: "{}",
                status: .success
            ))
        )
        viewModel.messages = [message]

        // When: Finding message for tool call
        let found = viewModel.findMessageId(for: .toolCall(id: "toolu_abc"))

        // Then: Should return the message ID
        XCTAssertEqual(found, messageId)
    }

    func testFindMessageIdForToolCallInToolResult() {
        // Given: A message with toolResult content
        let messageId = UUID()
        let message = ChatMessage(
            id: messageId,
            role: .user,
            content: .toolResult(ToolResultData(
                toolCallId: "toolu_abc",
                content: "Success",
                isError: false
            ))
        )
        viewModel.messages = [message]

        // When: Finding message for tool call
        let found = viewModel.findMessageId(for: .toolCall(id: "toolu_abc"))

        // Then: Should return the message ID
        XCTAssertEqual(found, messageId)
    }

    func testFindMessageIdForToolCallInSubagent() {
        // Given: A message with subagent content
        let messageId = UUID()
        let message = ChatMessage(
            id: messageId,
            role: .assistant,
            content: .subagent(SubagentToolData(
                toolCallId: "toolu_xyz",
                subagentSessionId: "sess_sub",
                task: "Do something",
                model: nil,
                status: .completed,
                currentTurn: 1
            ))
        )
        viewModel.messages = [message]

        // When: Finding message for tool call
        let found = viewModel.findMessageId(for: .toolCall(id: "toolu_xyz"))

        // Then: Should return the message ID
        XCTAssertEqual(found, messageId)
    }

    func testFindMessageIdForToolCallInAskUserQuestion() {
        // Given: A message with askUserQuestion content
        let messageId = UUID()
        let message = ChatMessage(
            id: messageId,
            role: .assistant,
            content: .askUserQuestion(AskUserQuestionToolData(
                toolCallId: "toolu_question",
                params: AskUserQuestionParams(
                    questions: [
                        AskUserQuestion(
                            id: "q1",
                            question: "Pick one?",
                            options: [
                                AskUserQuestionOption(label: "A", value: nil, description: nil),
                                AskUserQuestionOption(label: "B", value: nil, description: nil)
                            ],
                            mode: .single,
                            allowOther: nil,
                            otherPlaceholder: nil
                        )
                    ],
                    context: nil
                ),
                answers: [:],
                status: .pending,
                result: nil
            ))
        )
        viewModel.messages = [message]

        // When: Finding message for tool call
        let found = viewModel.findMessageId(for: .toolCall(id: "toolu_question"))

        // Then: Should return the message ID
        XCTAssertEqual(found, messageId)
    }

    func testFindMessageIdForToolCallInRenderAppUI() {
        // Given: A message with renderAppUI content
        let messageId = UUID()
        let message = ChatMessage(
            id: messageId,
            role: .assistant,
            content: .renderAppUI(RenderAppUIChipData(
                toolCallId: "toolu_render",
                canvasId: "canvas_123",
                title: "Test UI",
                status: .complete,
                errorMessage: nil
            ))
        )
        viewModel.messages = [message]

        // When: Finding message for tool call
        let found = viewModel.findMessageId(for: .toolCall(id: "toolu_render"))

        // Then: Should return the message ID
        XCTAssertEqual(found, messageId)
    }

    func testFindMessageIdForToolCallNotFound() {
        // Given: A message without matching tool call ID
        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: .text("Hello")
        )
        viewModel.messages = [message]

        // When: Finding message for non-existent tool call
        let found = viewModel.findMessageId(for: .toolCall(id: "toolu_nonexistent"))

        // Then: Should return nil
        XCTAssertNil(found)
    }

    func testFindMessageIdForToolCallWithMultipleMessages() {
        // Given: Multiple messages, only one matching
        let targetId = UUID()
        viewModel.messages = [
            ChatMessage(id: UUID(), role: .user, content: .text("Hello")),
            ChatMessage(id: UUID(), role: .assistant, content: .text("Hi there")),
            ChatMessage(
                id: targetId,
                role: .assistant,
                content: .toolUse(ToolUseData(
                    toolName: "NotifyApp",
                    toolCallId: "toolu_target",
                    arguments: "{}",
                    status: .success
                ))
            ),
            ChatMessage(id: UUID(), role: .assistant, content: .text("Done"))
        ]

        // When: Finding message for tool call
        let found = viewModel.findMessageId(for: .toolCall(id: "toolu_target"))

        // Then: Should return the correct message ID
        XCTAssertEqual(found, targetId)
    }

    // MARK: - Event ID Tests

    func testFindMessageIdForEventId() {
        // Given: A message with an event ID
        let messageId = UUID()
        let message = ChatMessage(
            id: messageId,
            role: .assistant,
            content: .text("Hello"),
            eventId: "evt_xyz"
        )
        viewModel.messages = [message]

        // When: Finding message for event
        let found = viewModel.findMessageId(for: .event(id: "evt_xyz"))

        // Then: Should return the message ID
        XCTAssertEqual(found, messageId)
    }

    func testFindMessageIdForEventIdNotFound() {
        // Given: A message with a different event ID
        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: .text("Hello"),
            eventId: "evt_other"
        )
        viewModel.messages = [message]

        // When: Finding message for non-existent event
        let found = viewModel.findMessageId(for: .event(id: "evt_nonexistent"))

        // Then: Should return nil
        XCTAssertNil(found)
    }

    // MARK: - Bottom Tests

    func testFindMessageIdForBottomReturnsNil() {
        // Given: Some messages
        viewModel.messages = [
            ChatMessage(id: UUID(), role: .user, content: .text("Hello")),
            ChatMessage(id: UUID(), role: .assistant, content: .text("Hi"))
        ]

        // When: Finding message for bottom
        let found = viewModel.findMessageId(for: .bottom)

        // Then: Should return nil (caller should use "bottom" anchor instead)
        XCTAssertNil(found)
    }

    // MARK: - Empty Messages Tests

    func testFindMessageIdWithEmptyMessages() {
        // Given: No messages
        viewModel.messages = []

        // When: Finding message
        let foundToolCall = viewModel.findMessageId(for: .toolCall(id: "toolu_abc"))
        let foundEvent = viewModel.findMessageId(for: .event(id: "evt_xyz"))
        let foundBottom = viewModel.findMessageId(for: .bottom)

        // Then: All should return nil
        XCTAssertNil(foundToolCall)
        XCTAssertNil(foundEvent)
        XCTAssertNil(foundBottom)
    }

    // MARK: - Full History Search Tests (for deep links to out-of-window messages)

    func testFindMessageIdSearchesAllReconstructedMessages() {
        // Given: A message in allReconstructedMessages but NOT in displayed messages
        let targetId = UUID()
        let targetMessage = ChatMessage(
            id: targetId,
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: "NotifyApp",
                toolCallId: "toolu_old",
                arguments: "{}",
                status: .success
            ))
        )

        // Simulate pagination: old message is in full history but not displayed
        viewModel.allReconstructedMessages = [
            targetMessage,  // Older message (not displayed)
            ChatMessage(id: UUID(), role: .user, content: .text("Hello")),
            ChatMessage(id: UUID(), role: .assistant, content: .text("Hi")),
        ]
        viewModel.messages = [
            ChatMessage(id: UUID(), role: .user, content: .text("Hello")),
            ChatMessage(id: UUID(), role: .assistant, content: .text("Hi")),
        ]

        // When: Finding message for tool call that's in full history
        let found = viewModel.findMessageId(for: .toolCall(id: "toolu_old"))

        // Then: Should find it in allReconstructedMessages
        XCTAssertEqual(found, targetId)
    }

    func testFindMessageIdSearchesDisplayedMessagesFirst() {
        // Given: A message in both displayed messages AND full history
        let targetId = UUID()
        let targetMessage = ChatMessage(
            id: targetId,
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: "NotifyApp",
                toolCallId: "toolu_recent",
                arguments: "{}",
                status: .success
            ))
        )

        // Message is in both arrays (as would happen normally)
        viewModel.messages = [targetMessage]
        viewModel.allReconstructedMessages = [
            ChatMessage(id: UUID(), role: .user, content: .text("Old message")),
            targetMessage,
        ]

        // When: Finding message for tool call
        let found = viewModel.findMessageId(for: .toolCall(id: "toolu_recent"))

        // Then: Should find it (displayed messages searched first)
        XCTAssertEqual(found, targetId)
    }

    func testFindMessageIdForEventSearchesFullHistory() {
        // Given: An event in full history but not displayed
        let targetId = UUID()
        let targetMessage = ChatMessage(
            id: targetId,
            role: .assistant,
            content: .text("Old notification"),
            eventId: "evt_old"
        )

        viewModel.allReconstructedMessages = [targetMessage]
        viewModel.messages = []

        // When: Finding message for event
        let found = viewModel.findMessageId(for: .event(id: "evt_old"))

        // Then: Should find it in full history
        XCTAssertEqual(found, targetId)
    }

    func testFindMessageIdExpandsWindowForOldMessage() {
        // Given: A deep link target that's beyond the displayed window
        let targetId = UUID()
        let targetMessage = ChatMessage(
            id: targetId,
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: "NotifyApp",
                toolCallId: "toolu_old",
                arguments: "{}",
                status: .success
            ))
        )

        // Build a realistic scenario: 60 messages total, only latest 50 displayed
        var allMessages: [ChatMessage] = []
        allMessages.append(targetMessage)  // Index 0 (oldest)
        for i in 1..<60 {
            allMessages.append(ChatMessage(
                id: UUID(),
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: .text("Message \(i)")
            ))
        }

        viewModel.allReconstructedMessages = allMessages
        viewModel.messages = Array(allMessages.suffix(50))  // Only latest 50
        viewModel.displayedMessageCount = 50

        // When: Finding the old message
        let found = viewModel.findMessageId(for: .toolCall(id: "toolu_old"))

        // Then: Should find it
        XCTAssertEqual(found, targetId)

        // And: Window should be expanded to include it
        XCTAssertTrue(viewModel.messages.contains(where: { $0.id == targetId }))
    }

    func testFindMessageIdReturnsIndexInFullHistory() {
        // Given: A message that needs window expansion
        let targetId = UUID()
        let targetMessage = ChatMessage(
            id: targetId,
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: "NotifyApp",
                toolCallId: "toolu_target",
                arguments: "{}",
                status: .success
            ))
        )

        viewModel.allReconstructedMessages = [
            targetMessage,
            ChatMessage(id: UUID(), role: .user, content: .text("Middle")),
            ChatMessage(id: UUID(), role: .assistant, content: .text("End")),
        ]
        viewModel.messages = [
            ChatMessage(id: UUID(), role: .assistant, content: .text("End")),
        ]
        viewModel.displayedMessageCount = 1

        // When: Finding the message
        let found = viewModel.findMessageId(for: .toolCall(id: "toolu_target"))

        // Then: Should return the message ID
        XCTAssertEqual(found, targetId)
    }
}
