import XCTest
@testable import TronMobile

/// Tests for ChatViewModel.findMessageId(for:) method
/// This method is used by deep linking to find the message UUID for a scroll target
@MainActor
final class ChatViewModelFindMessageTests: XCTestCase {

    var viewModel: ChatViewModel!

    override func setUp() async throws {
        // Create a minimal ChatViewModel for testing
        // Note: We don't need a real engine client for these tests since we're only
        // testing the findMessageId method which works on local messages array
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        viewModel = ChatViewModel(engineClient: engineClient, sessionId: "test-session")
    }

    override func tearDown() async throws {
        viewModel = nil
    }

    // MARK: - Tool Call Tests

    func testFindMessageIdForToolInvocationInToolInvocation() {
        // Given: A message with tool invocation content
        let messageId = UUID()
        let message = ChatMessage(
            id: messageId,
            role: .assistant,
            content: .toolInvocation(testToolInvocation(id: "toolu_abc", status: .success))
        )
        viewModel.messages = [message]

        // When: Finding message for tool invocation
        let found = viewModel.findMessageId(for: .toolInvocation(id: "toolu_abc"))

        // Then: Should return the message ID
        XCTAssertEqual(found, messageId)
    }

    func testFindMessageIdForToolInvocationInToolResult() {
        // Given: A message with orphan tool result content
        let messageId = UUID()
        let message = ChatMessage(
            id: messageId,
            role: .user,
            content: .toolResult(testToolResult(id: "toolu_abc", content: "Success"))
        )
        viewModel.messages = [message]

        // When: Finding message for tool invocation
        let found = viewModel.findMessageId(for: .toolInvocation(id: "toolu_abc"))

        // Then: Should return the message ID
        XCTAssertEqual(found, messageId)
    }

    func testFindMessageIdForToolInvocationNotFound() {
        // Given: A message without matching tool invocation ID
        let message = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: .text("Hello")
        )
        viewModel.messages = [message]

        // When: Finding message for non-existent tool invocation
        let found = viewModel.findMessageId(for: .toolInvocation(id: "toolu_nonexistent"))

        // Then: Should return nil
        XCTAssertNil(found)
    }

    func testFindMessageIdForToolInvocationWithMultipleMessages() {
        // Given: Multiple messages, only one matching
        let targetId = UUID()
        viewModel.messages = [
            ChatMessage(id: UUID(), role: .user, content: .text("Hello")),
            ChatMessage(id: UUID(), role: .assistant, content: .text("Hi there")),
            ChatMessage(
                id: targetId,
                role: .assistant,
                content: .toolInvocation(testToolInvocation(id: "toolu_target", status: .success))
            ),
            ChatMessage(id: UUID(), role: .assistant, content: .text("Done"))
        ]

        // When: Finding message for tool invocation
        let found = viewModel.findMessageId(for: .toolInvocation(id: "toolu_target"))

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
        let foundToolInvocation = viewModel.findMessageId(for: .toolInvocation(id: "toolu_abc"))
        let foundEvent = viewModel.findMessageId(for: .event(id: "evt_xyz"))
        let foundBottom = viewModel.findMessageId(for: .bottom)

        // Then: All should return nil
        XCTAssertNil(foundToolInvocation)
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
            content: .toolInvocation(testToolInvocation(id: "toolu_old", status: .success))
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

        // When: Finding message for tool invocation that's in full history
        let found = viewModel.findMessageId(for: .toolInvocation(id: "toolu_old"))

        // Then: Should find it in allReconstructedMessages
        XCTAssertEqual(found, targetId)
    }

    func testFindMessageIdSearchesDisplayedMessagesFirst() {
        // Given: A message in both displayed messages AND full history
        let targetId = UUID()
        let targetMessage = ChatMessage(
            id: targetId,
            role: .assistant,
            content: .toolInvocation(testToolInvocation(id: "toolu_recent", status: .success))
        )

        // Message is in both arrays (as would happen normally)
        viewModel.messages = [targetMessage]
        viewModel.allReconstructedMessages = [
            ChatMessage(id: UUID(), role: .user, content: .text("Old message")),
            targetMessage,
        ]

        // When: Finding message for tool invocation
        let found = viewModel.findMessageId(for: .toolInvocation(id: "toolu_recent"))

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

    func testResolveMessageIdForDeepLinkLoadsOlderHistoryUntilTargetExists() async {
        let targetId = UUID()
        let targetMessage = ChatMessage(
            id: targetId,
            role: .assistant,
            content: .toolInvocation(testToolInvocation(id: "toolu_target", status: .success))
        )

        viewModel.allReconstructedMessages = [
            ChatMessage(id: UUID(), role: .user, content: .text("Recent")),
        ]
        viewModel.messages = viewModel.allReconstructedMessages
        viewModel.displayedMessageCount = 1
        viewModel.hasMoreMessages = true

        var loadCount = 0
        let found = await viewModel.resolveMessageIdForDeepLink(.toolInvocation(id: "toolu_target")) {
            loadCount += 1
            self.viewModel.allReconstructedMessages.insert(targetMessage, at: 0)
            self.viewModel.insertAtFrontOfMessages([targetMessage])
            self.viewModel.displayedMessageCount += 1
            self.viewModel.hasMoreMessages = false
        }

        XCTAssertEqual(found, targetId)
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(viewModel.messages.contains(where: { $0.id == targetId }))
    }

    func testResolveMessageIdForDeepLinkStopsWhenPaginationMakesNoProgress() async {
        viewModel.allReconstructedMessages = [
            ChatMessage(id: UUID(), role: .user, content: .text("Recent")),
        ]
        viewModel.messages = viewModel.allReconstructedMessages
        viewModel.displayedMessageCount = 1
        viewModel.hasMoreMessages = true

        var loadCount = 0
        let found = await viewModel.resolveMessageIdForDeepLink(.event(id: "evt_missing")) {
            loadCount += 1
        }

        XCTAssertNil(found)
        XCTAssertEqual(loadCount, 1)
    }

    func testResolveMessageIdForDeepLinkContinuesFromPrunedBatchToServerCursor() async {
        let (viewModel, sessions) = makeDeepLinkViewModel()
        self.viewModel = viewModel

        let targetEventId = "event-target"
        let visibleMessage = makeMessage("visible recent")
        viewModel.allReconstructedMessages = [visibleMessage]
        viewModel.replaceAllMessages(with: [visibleMessage])
        viewModel.displayedMessageCount = 1
        viewModel.prunedLiveMessages = (0..<ChatViewModel.additionalMessageBatchSize).map { index in
            makeMessage("pruned \(index)")
        }
        viewModel.reconstructionOldestEventId = "cursor-live"
        viewModel.hasOlderServerReconstructionPages = true
        viewModel.recomputeHasMoreMessages()

        sessions.reconstructHandler = { _, _, beforeEventId in
            XCTAssertEqual(beforeEventId, "cursor-live")
            return self.reconstructResult(
                events: [
                    self.rawEvent(
                        id: targetEventId,
                        type: "message.user",
                        content: "older target",
                        sequence: 1
                    )
                ],
                hasMoreEvents: false,
                oldestEventId: "cursor-root"
            )
        }

        let found = await viewModel.resolveMessageIdForDeepLink(.event(id: targetEventId))

        XCTAssertNotNil(found)
        XCTAssertEqual(sessions.reconstructCalls.map(\.beforeEventId), ["cursor-live"])
        XCTAssertTrue(viewModel.prunedLiveMessages.isEmpty)
        XCTAssertTrue(viewModel.messages.contains(where: { $0.eventId == targetEventId }))
        XCTAssertEqual(viewModel.reconstructionOldestEventId, "cursor-root")
        XCTAssertFalse(viewModel.hasMoreMessages)
    }

    func testFindMessageIdExpandsWindowForOldMessage() {
        // Given: A deep link target that's beyond the displayed window
        let targetId = UUID()
        let targetMessage = ChatMessage(
            id: targetId,
            role: .assistant,
            content: .toolInvocation(testToolInvocation(id: "toolu_old", status: .success))
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
        let found = viewModel.findMessageId(for: .toolInvocation(id: "toolu_old"))

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
            content: .toolInvocation(testToolInvocation(id: "toolu_target", status: .success))
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
        let found = viewModel.findMessageId(for: .toolInvocation(id: "toolu_target"))

        // Then: Should return the message ID
        XCTAssertEqual(found, targetId)
    }

    // MARK: - Helpers

    private func makeDeepLinkViewModel() -> (ChatViewModel, DeepLinkTestSessionRepository) {
        let transport = MockEngineTransport()
        let sessions = DeepLinkTestSessionRepository()
        let services = ChatSessionServices(
            connection: DeepLinkTestConnectionRepository(),
            events: DeepLinkTestSessionEventRepository(),
            sessions: sessions,
            agent: AgentClient(transport: transport),
            models: DefaultModelRepository(modelClient: ModelClient(transport: transport)),
            messages: DefaultMessageRepository(messageClient: MessageClient(transport: transport)),
            workerKernel: DefaultWorkerKernelRepository(client: WorkerKernelClient(transport: transport))
        )
        return (ChatViewModel(services: services, sessionId: "test-session"), sessions)
    }

    private func makeMessage(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .text(text), timestamp: Date())
    }

    private func reconstructResult(
        events: [RawEvent],
        hasMoreEvents: Bool,
        oldestEventId: String?
    ) -> SessionReconstructResult {
        SessionReconstructResult(
            events: events,
            hasMoreEvents: hasMoreEvents,
            oldestEventId: oldestEventId,
            inFlight: nil,
            lastSequence: Int64(events.map(\.sequence).max() ?? 0),
            isRunning: false,
            isCompacting: false,
            compactionReason: nil,
            agentPhase: "idle",
            metadata: ReconstructMetadata(
                model: nil,
                turnCount: nil,
                workingDirectory: nil,
                title: nil,
                tokenUsage: nil,
                totalCost: nil
            )
        )
    }

    private func rawEvent(
        id: String,
        type: String,
        content: String,
        sequence: Int
    ) -> RawEvent {
        RawEvent(
            id: id,
            parentId: nil,
            sessionId: "test-session",
            workspaceId: "/test/workspace",
            type: type,
            timestamp: "2026-01-01T00:00:00Z",
            sequence: sequence,
            payload: ["content": AnyCodable(content)]
        )
    }
}

@MainActor
private final class DeepLinkTestConnectionRepository: AppConnectionRepository {
    var connectionState: ConnectionState = .connected

    func connect() async {}
}

@MainActor
private final class DeepLinkTestSessionEventRepository: SessionEventRepository {
    var currentSessionId: String?
    var currentModel: String = "claude-sonnet-4"
    var hasActiveSession: Bool = true

    func events(for sessionId: String?) -> AsyncStream<ParsedEventV2> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func ensureSessionEventSubscription(sessionId: String, workspaceId: String?) async throws {}
}

@MainActor
private final class DeepLinkTestSessionRepository: NetworkSessionRepository {
    var reconstructCalls: [(sessionId: String, limit: Int?, beforeEventId: String?)] = []
    var reconstructHandler: ((String, Int?, String?) async throws -> SessionReconstructResult)?

    func create(
        workingDirectory: String,
        model: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> SessionCreateResult {
        throw EngineConnectionError.invalidResponse
    }

    func list(
        workingDirectory: String?,
        limit: Int,
        cursor: String?,
        includeArchived: Bool
    ) async throws -> SessionListResult {
        throw EngineConnectionError.invalidResponse
    }

    func resume(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {}

    func reconstruct(sessionId: String, limit: Int?, beforeEventId: String?) async throws -> SessionReconstructResult {
        reconstructCalls.append((sessionId: sessionId, limit: limit, beforeEventId: beforeEventId))
        guard let reconstructHandler else {
            throw EngineConnectionError.invalidResponse
        }
        return try await reconstructHandler(sessionId, limit, beforeEventId)
    }

    func archive(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {}
    func unarchive(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {}

    func fork(
        sessionId: String,
        fromEventId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> SessionForkResult {
        throw EngineConnectionError.invalidResponse
    }

    func getHistory(limit: Int) async throws -> [HistoryMessage] {
        []
    }
}
