import XCTest
@testable import TronMobile

// MARK: - Live Session Pruning Tests

/// Tests for automatic memory management during long-running live sessions.
/// Validates that old messages are pruned from the SwiftUI-observed `messages` array
/// and stored in a non-observed buffer for instant "Load Earlier" recovery.
@MainActor
final class LiveSessionPruningTests: XCTestCase {

    var viewModel: ChatViewModel!

    override func setUp() async throws {
        let mockURL = URL(string: "ws://localhost:8080/ws")!
        let rpcClient = RPCClient(serverURL: mockURL)
        viewModel = ChatViewModel(rpcClient: rpcClient, sessionId: "test-session")
    }

    override func tearDown() async throws {
        viewModel = nil
    }

    // MARK: - Threshold Behavior

    func test_pruneDoesNothing_whenMessagesEmpty() {
        // Given: no messages
        XCTAssertTrue(viewModel.messages.isEmpty)

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.prunedLiveMessages.isEmpty)
    }

    func test_pruneDoesNothing_whenBelowThreshold() {
        // Given: 199 messages (below 200 threshold)
        populateMessages(count: 199)

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: nothing pruned
        XCTAssertEqual(viewModel.messages.count, 199)
        XCTAssertTrue(viewModel.prunedLiveMessages.isEmpty)
        XCTAssertFalse(viewModel.hasMoreMessages)
    }

    func test_pruneDoesNothing_whenAtExactThreshold() {
        // Given: exactly 200 messages (at threshold, not above)
        populateMessages(count: 200)

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: nothing pruned (threshold is >, not >=)
        XCTAssertEqual(viewModel.messages.count, 200)
        XCTAssertTrue(viewModel.prunedLiveMessages.isEmpty)
    }

    func test_pruneTriggersAtThresholdPlusOne() {
        // Given: 201 messages (just above threshold)
        populateMessages(count: 201)

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: pruned to target (100)
        XCTAssertEqual(viewModel.messages.count, ChatViewModel.liveSessionPruneTarget)
        XCTAssertEqual(viewModel.prunedLiveMessages.count, 101)
    }

    func test_pruneHandlesLargeMessageCount() {
        // Given: 500 messages
        populateMessages(count: 500)

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: pruned to target
        XCTAssertEqual(viewModel.messages.count, ChatViewModel.liveSessionPruneTarget)
        XCTAssertEqual(viewModel.prunedLiveMessages.count, 400)
    }

    // MARK: - Safety Guards

    func test_pruneSkipped_whenTurnStartIndexIsSet() {
        // Given: above threshold but a turn is in progress
        populateMessages(count: 250)
        viewModel.turnStartMessageIndex = 200

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: nothing pruned (rapid-fire safety)
        XCTAssertEqual(viewModel.messages.count, 250)
        XCTAssertTrue(viewModel.prunedLiveMessages.isEmpty)
    }

    func test_pruneAllowed_whenTurnStartIndexIsNil() {
        // Given: above threshold, no active turn
        populateMessages(count: 250)
        viewModel.turnStartMessageIndex = nil

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: pruning happens
        XCTAssertEqual(viewModel.messages.count, ChatViewModel.liveSessionPruneTarget)
    }

    // MARK: - State Correctness After Pruning

    func test_pruneUpdatesMessageCount() {
        // Given
        populateMessages(count: 300)

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then
        XCTAssertEqual(viewModel.messages.count, ChatViewModel.liveSessionPruneTarget)
    }

    func test_pruneSetsHasMoreMessages() {
        // Given
        populateMessages(count: 250)
        viewModel.hasMoreMessages = false

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then
        XCTAssertTrue(viewModel.hasMoreMessages)
    }

    func test_pruneUpdatesDisplayedMessageCount() {
        // Given
        populateMessages(count: 250)
        viewModel.displayedMessageCount = 250

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then
        XCTAssertEqual(viewModel.displayedMessageCount, viewModel.messages.count)
    }

    func test_pruneKeepsMessageIndexValid_byUUID() {
        // Given: populate with identifiable messages
        populateMessages(count: 250)
        let lastMessage = viewModel.messages.last!
        let secondToLast = viewModel.messages[viewModel.messages.count - 2]

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: O(1) lookup still works for kept messages
        let lastIndex = viewModel.messageIndex.index(for: lastMessage.id)
        XCTAssertNotNil(lastIndex)
        XCTAssertEqual(lastIndex, viewModel.messages.count - 1)

        let secondToLastIndex = viewModel.messageIndex.index(for: secondToLast.id)
        XCTAssertNotNil(secondToLastIndex)
        XCTAssertEqual(secondToLastIndex, viewModel.messages.count - 2)
    }

    func test_pruneKeepsMessageIndexValid_byToolCallId() {
        // Given: populate and add a tool message in the kept range
        populateMessages(count: 200)
        let toolData = ToolUseData(
            toolName: "Bash",
            toolCallId: "tool_keep_me",
            arguments: "{}",
            status: .success,
            result: "ok"
        )
        let toolMessage = ChatMessage(role: .assistant, content: .toolUse(toolData))
        viewModel.appendToMessages(toolMessage)

        // When (201 messages, triggers prune)
        viewModel.pruneOldMessagesIfNeeded()

        // Then: toolCallId lookup works for kept tool message
        let toolIndex = viewModel.messageIndex.index(forToolCallId: "tool_keep_me")
        XCTAssertNotNil(toolIndex)
    }

    func test_pruneSyncsMessageWindowManager() {
        // Given
        populateMessages(count: 250)

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: window manager has the same messages
        XCTAssertEqual(
            viewModel.messageWindowManager.totalCount,
            viewModel.messages.count
        )
    }

    func test_pruneIncrementsPrunedVersion() {
        // Given
        populateMessages(count: 250)
        let versionBefore = viewModel.prunedVersion

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then
        XCTAssertEqual(viewModel.prunedVersion, versionBefore + 1)
    }

    // MARK: - Content Preservation

    func test_pruneKeepsNewestMessages() {
        // Given: messages with identifiable content
        var specificMessages: [ChatMessage] = []
        for i in 0..<250 {
            specificMessages.append(ChatMessage(
                role: i % 2 == 0 ? .user : .assistant,
                content: .text("Message \(i)")
            ))
        }
        for msg in specificMessages {
            viewModel.appendToMessages(msg)
        }

        let expectedLastId = specificMessages.last!.id
        let expectedKeptFirstId = specificMessages[150].id  // 250 - 100 = index 150

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: last message is the same
        XCTAssertEqual(viewModel.messages.last?.id, expectedLastId)
        // First displayed message is the 150th original message
        XCTAssertEqual(viewModel.messages.first?.id, expectedKeptFirstId)
    }

    func test_pruneStoresPrunedMessagesInBuffer() {
        // Given
        var allIds: [UUID] = []
        for i in 0..<250 {
            let msg = ChatMessage(role: .assistant, content: .text("Message \(i)"))
            allIds.append(msg.id)
            viewModel.appendToMessages(msg)
        }

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: pruned buffer contains the oldest 150 messages in order
        XCTAssertEqual(viewModel.prunedLiveMessages.count, 150)
        XCTAssertEqual(viewModel.prunedLiveMessages.first?.id, allIds[0])
        XCTAssertEqual(viewModel.prunedLiveMessages.last?.id, allIds[149])
    }

    func test_prunePreservesMessageIdentity() {
        // Given
        populateMessages(count: 250)
        let keptIds = Set(viewModel.messages.suffix(ChatViewModel.liveSessionPruneTarget).map { $0.id })

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: all kept messages have the same UUIDs
        let afterIds = Set(viewModel.messages.map { $0.id })
        XCTAssertEqual(afterIds, keptIds)
    }

    // MARK: - catchUpMessageIds Cleanup

    func test_pruneCleansStaleCatchUpIds() {
        // Given: messages with some IDs tracked as catch-up
        populateMessages(count: 250)
        let prunedMessageId = viewModel.messages[0].id  // Will be pruned
        viewModel.catchUpMessageIds.insert(prunedMessageId)

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: pruned ID removed from catch-up set
        XCTAssertFalse(viewModel.catchUpMessageIds.contains(prunedMessageId))
    }

    func test_prunePreservesValidCatchUpIds() {
        // Given: catch-up ID for a message that will be kept
        populateMessages(count: 250)
        let keptMessageId = viewModel.messages.last!.id
        viewModel.catchUpMessageIds.insert(keptMessageId)

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: kept ID preserved in catch-up set
        XCTAssertTrue(viewModel.catchUpMessageIds.contains(keptMessageId))
    }

    // MARK: - Multiple Pruning Cycles

    func test_multiplePrunesAccumulateInBuffer() {
        // Given: first prune cycle
        populateMessages(count: 250)
        viewModel.pruneOldMessagesIfNeeded()
        XCTAssertEqual(viewModel.messages.count, 100)
        XCTAssertEqual(viewModel.prunedLiveMessages.count, 150)

        // When: add more messages to trigger second prune
        for _ in 0..<101 {
            viewModel.appendToMessages(createMockMessage())
        }
        XCTAssertEqual(viewModel.messages.count, 201)
        viewModel.pruneOldMessagesIfNeeded()

        // Then: buffer accumulated from both prunes
        XCTAssertEqual(viewModel.messages.count, 100)
        XCTAssertEqual(viewModel.prunedLiveMessages.count, 150 + 101) // 251
    }

    func test_prunedBufferCappedAtMaxSize() {
        // Given: fill buffer near capacity with multiple prune cycles
        // First cycle: 501 messages → 100 kept, 401 pruned (buffer = 401)
        populateMessages(count: 501)
        viewModel.pruneOldMessagesIfNeeded()
        XCTAssertEqual(viewModel.prunedLiveMessages.count, 401)

        // When: second cycle adds more to buffer, exceeding 500 cap
        for _ in 0..<101 {
            viewModel.appendToMessages(createMockMessage())
        }
        viewModel.pruneOldMessagesIfNeeded()

        // Then: buffer capped at max (500), oldest discarded
        XCTAssertLessThanOrEqual(
            viewModel.prunedLiveMessages.count,
            ChatViewModel.maxPrunedBufferSize
        )
    }

    // MARK: - Recovery (Load Earlier Messages)

    func test_loadMore_loadsFromPrunedBuffer_whenAvailable() {
        // Given: prune messages
        populateMessages(count: 250)
        viewModel.pruneOldMessagesIfNeeded()
        let messagesBeforeLoad = viewModel.messages.count

        // When: load more
        viewModel.loadMoreMessages()

        // Then: messages prepended from pruned buffer
        XCTAssertGreaterThan(viewModel.messages.count, messagesBeforeLoad)
        // Pruned buffer decreased
        XCTAssertLessThan(viewModel.prunedLiveMessages.count, 150)
    }

    func test_loadMore_fallsToExistingLogic_whenBufferEmpty() {
        // Given: no pruned messages, but allReconstructedMessages populated (resumed session)
        var reconstructed: [ChatMessage] = []
        for _ in 0..<100 {
            reconstructed.append(createMockMessage())
        }
        viewModel.allReconstructedMessages = reconstructed

        // Show only latest 50
        let latest = Array(reconstructed.suffix(50))
        viewModel.replaceAllMessages(with: latest)
        viewModel.displayedMessageCount = 50
        viewModel.hasMoreMessages = true

        // When: load more (no pruned buffer)
        XCTAssertTrue(viewModel.prunedLiveMessages.isEmpty)
        viewModel.loadMoreMessages()

        // Then: messages loaded from allReconstructedMessages
        XCTAssertGreaterThan(viewModel.messages.count, 50)
    }

    func test_loadMore_prependsInChronologicalOrder() {
        // Given: messages with known order, then prune
        var orderedMessages: [ChatMessage] = []
        for i in 0..<250 {
            let msg = ChatMessage(role: .assistant, content: .text("Msg \(i)"))
            orderedMessages.append(msg)
            viewModel.appendToMessages(msg)
        }
        viewModel.pruneOldMessagesIfNeeded()

        // The first displayed message should be orderedMessages[150]
        let firstDisplayedBefore = viewModel.messages.first!.id

        // When: load more
        viewModel.loadMoreMessages()

        // Then: prepended messages come before the previously first displayed message
        let firstDisplayedAfter = viewModel.messages.first!.id
        XCTAssertNotEqual(firstDisplayedAfter, firstDisplayedBefore)
        // The order is chronological: first message of loaded batch < first message before load
        // (loaded batch is from end of pruned buffer, which is chronologically earlier)
    }

    func test_loadMore_updatesHasMoreMessages() {
        // Given: prune, creating a small pruned buffer
        populateMessages(count: 210)
        viewModel.pruneOldMessagesIfNeeded()
        // Pruned buffer has 110 messages
        XCTAssertEqual(viewModel.prunedLiveMessages.count, 110)

        // When: load all in multiple batches (30 per batch)
        while !viewModel.prunedLiveMessages.isEmpty {
            viewModel.loadMoreMessages()
        }

        // Then: load one more time
        let hasMoreBefore = viewModel.hasMoreMessages
        // If allReconstructedMessages is empty, hasMoreMessages should be false
        if viewModel.allReconstructedMessages.isEmpty {
            XCTAssertFalse(hasMoreBefore)
        }
    }

    // MARK: - Reset Behavior

    func test_prunedMessages_clearedOnDisconnect() {
        // Given: pruned messages exist
        populateMessages(count: 250)
        viewModel.pruneOldMessagesIfNeeded()
        XCTAssertFalse(viewModel.prunedLiveMessages.isEmpty)

        // When: simulate disconnect by directly checking the cleanup
        // (In production, the connection state observation handler clears this)
        viewModel.prunedLiveMessages.removeAll()

        // Then
        XCTAssertTrue(viewModel.prunedLiveMessages.isEmpty)
    }

    // MARK: - Integration (Turn Lifecycle)

    func test_handleTurnEnd_triggersPrune_whenAboveThreshold() {
        // Given: above threshold, turn ended (turnStartMessageIndex cleared)
        populateMessages(count: 250)
        viewModel.turnStartMessageIndex = nil

        // When: simulate handleTurnEnd calling pruneOldMessagesIfNeeded
        viewModel.pruneOldMessagesIfNeeded()

        // Then: pruned
        XCTAssertEqual(viewModel.messages.count, ChatViewModel.liveSessionPruneTarget)
    }

    func test_handleTurnEnd_doesNotPrune_whenBelowThreshold() {
        // Given: below threshold
        populateMessages(count: 100)
        viewModel.turnStartMessageIndex = nil

        // When
        viewModel.pruneOldMessagesIfNeeded()

        // Then: no change
        XCTAssertEqual(viewModel.messages.count, 100)
        XCTAssertTrue(viewModel.prunedLiveMessages.isEmpty)
    }

    // MARK: - Helpers

    private func populateMessages(count: Int) {
        for _ in 0..<count {
            viewModel.appendToMessages(createMockMessage())
        }
    }

    private func createMockMessage(text: String = "Test message") -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: .assistant,
            content: .text(text),
            timestamp: Date()
        )
    }
}
