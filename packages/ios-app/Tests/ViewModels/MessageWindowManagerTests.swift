import XCTest
@testable import TronMobile

// MARK: - Mock Message Window Data Source

@MainActor
final class MockMessageWindowDataSource: MessageWindowDataSource {
    var messages: [ChatMessage] = []
    var hasMoreBeforeResult: Bool = false
    var hasMoreAfterResult: Bool = false

    func loadLatestMessages(count: Int) async -> [ChatMessage] {
        Array(messages.suffix(count))
    }

    func loadMessages(before id: UUID?, count: Int) async -> [ChatMessage] {
        guard let id = id,
              let index = messages.firstIndex(where: { $0.id == id }) else {
            return []
        }
        let startIndex = max(0, index - count)
        return Array(messages[startIndex..<index])
    }

    func loadMessages(after id: UUID?, count: Int) async -> [ChatMessage] {
        guard let id = id,
              let index = messages.firstIndex(where: { $0.id == id }) else {
            return []
        }
        let endIndex = min(messages.count, index + 1 + count)
        return Array(messages[(index + 1)..<endIndex])
    }

    func hasMoreMessages(before id: UUID?) async -> Bool {
        hasMoreBeforeResult
    }

    func hasMoreMessages(after id: UUID?) async -> Bool {
        hasMoreAfterResult
    }
}

// MARK: - MessageWindowManager Tests

@MainActor
final class MessageWindowManagerTests: XCTestCase {

    var manager: MessageWindowManager!
    var mockDataSource: MockMessageWindowDataSource!

    override func setUp() async throws {
        manager = MessageWindowManager()
        mockDataSource = MockMessageWindowDataSource()
        manager.dataSource = mockDataSource
    }

    override func tearDown() async throws {
        manager.reset()
        manager = nil
        mockDataSource = nil
    }

    // MARK: - Initial State Tests

    func test_initialState_isEmpty() {
        XCTAssertEqual(manager.totalCount, 0)
        XCTAssertEqual(manager.currentWindowSize, 0)
        XCTAssertTrue(manager.windowedMessages.isEmpty)
    }

    func test_initialState_noLoadingFlags() {
        XCTAssertFalse(manager.isLoadingOlder)
        XCTAssertFalse(manager.isLoadingNewer)
        XCTAssertFalse(manager.hasMoreOlder)
        XCTAssertFalse(manager.hasMoreNewer)
    }

    // MARK: - Load Initial Tests

    func test_loadInitial_loadsMessages() async {
        // Given
        mockDataSource.messages = createMockMessages(count: 10)

        // When
        await manager.loadInitial()

        // Then
        XCTAssertEqual(manager.totalCount, 10)
        XCTAssertEqual(manager.windowedMessages.count, 10)
    }

    func test_loadInitial_setsHasMoreOlder() async {
        // Given
        mockDataSource.messages = createMockMessages(count: 10)
        mockDataSource.hasMoreBeforeResult = true

        // When
        await manager.loadInitial()

        // Then
        XCTAssertTrue(manager.hasMoreOlder)
        XCTAssertFalse(manager.hasMoreNewer)
    }

    func test_loadInitial_limitsToInitialCount() async {
        // Given - more messages than initial load count
        mockDataSource.messages = createMockMessages(count: 100)

        // When
        await manager.loadInitial()

        // Then - window size limited
        XCTAssertLessThanOrEqual(manager.currentWindowSize, MessageWindowManager.Config.initialLoadCount)
    }

    // MARK: - Append Message Tests

    func test_appendMessage_addsToEnd() {
        // Given
        let message = createMockMessage()

        // When
        manager.appendMessage(message)

        // Then
        XCTAssertEqual(manager.totalCount, 1)
        XCTAssertEqual(manager.windowedMessages.first?.id, message.id)
    }

    func test_appendMessage_expandsWindow() {
        // Given
        for _ in 0..<5 {
            manager.appendMessage(createMockMessage())
        }

        // When
        let newMessage = createMockMessage()
        manager.appendMessage(newMessage)

        // Then
        XCTAssertEqual(manager.totalCount, 6)
        XCTAssertEqual(manager.windowedMessages.last?.id, newMessage.id)
    }

    // MARK: - Update Message Tests

    func test_updateMessage_updatesExisting() {
        // Given
        let original = createMockMessage(text: "Original")
        manager.appendMessage(original)

        // When
        let updated = ChatMessage(
            id: original.id,
            role: .assistant,
            content: .text("Updated"),
            timestamp: Date()
        )
        manager.updateMessage(updated)

        // Then
        if case .text(let text) = manager.windowedMessages.first?.content {
            XCTAssertEqual(text, "Updated")
        } else {
            XCTFail("Expected text content")
        }
    }

    func test_updateMessage_ignoresToNonexistent() {
        // Given
        let message = createMockMessage()
        // Don't append it

        // When
        manager.updateMessage(message)

        // Then - no crash, nothing added
        XCTAssertEqual(manager.totalCount, 0)
    }

    // MARK: - Remove Message Tests

    func test_removeMessage_removesFromList() {
        // Given
        let message = createMockMessage()
        manager.appendMessage(message)

        // When
        manager.removeMessage(id: message.id)

        // Then
        XCTAssertEqual(manager.totalCount, 0)
        XCTAssertTrue(manager.windowedMessages.isEmpty)
    }

    func test_removeMessage_adjustsWindowBounds() {
        // Given
        let messages = (0..<5).map { _ in createMockMessage() }
        messages.forEach { manager.appendMessage($0) }

        // When - remove middle message
        manager.removeMessage(id: messages[2].id)

        // Then
        XCTAssertEqual(manager.totalCount, 4)
    }

    // MARK: - Reset Tests

    func test_reset_clearsAllState() {
        // Given
        for _ in 0..<5 {
            manager.appendMessage(createMockMessage())
        }

        // When
        manager.reset()

        // Then
        XCTAssertEqual(manager.totalCount, 0)
        XCTAssertEqual(manager.currentWindowSize, 0)
        XCTAssertTrue(manager.windowedMessages.isEmpty)
        XCTAssertFalse(manager.hasMoreOlder)
        XCTAssertFalse(manager.hasMoreNewer)
    }

    // MARK: - Reload Tests

    func test_reload_replacesAllMessages() {
        // Given
        for _ in 0..<3 {
            manager.appendMessage(createMockMessage())
        }

        // When
        let newMessages = createMockMessages(count: 5)
        manager.reload(with: newMessages)

        // Then
        XCTAssertEqual(manager.totalCount, 5)
    }

    // MARK: - Placeholder Height Tests

    func test_topPlaceholderHeight_zeroWhenAtTop() {
        // Given - load initial (window starts at 0)
        for _ in 0..<10 {
            manager.appendMessage(createMockMessage())
        }

        // Then
        XCTAssertEqual(manager.topPlaceholderHeight, 0)
    }

    func test_bottomPlaceholderHeight_zeroWhenAtBottom() {
        // Given
        for _ in 0..<10 {
            manager.appendMessage(createMockMessage())
        }

        // Then
        XCTAssertEqual(manager.bottomPlaceholderHeight, 0)
    }

    // MARK: - Update Estimated Height Tests

    func test_updateEstimatedHeight_storesHeight() {
        // Given
        let message = createMockMessage()
        manager.appendMessage(message)

        // When
        manager.updateEstimatedHeight(for: message.id, height: 150)

        // Then - height should be stored for future use
        // No direct assertion available, but no crash
    }

    // MARK: - Configuration Tests

    func test_configConstants_areReasonable() {
        XCTAssertGreaterThan(MessageWindowManager.Config.initialLoadCount, 0)
        XCTAssertGreaterThan(MessageWindowManager.Config.loadMoreCount, 0)
        XCTAssertGreaterThan(MessageWindowManager.Config.maxWindowSize, MessageWindowManager.Config.initialLoadCount)
    }

    // MARK: - Helpers

    private func createMockMessage(text: String = "Test message") -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: .assistant,
            content: .text(text),
            timestamp: Date()
        )
    }

    private func createMockMessages(count: Int) -> [ChatMessage] {
        (0..<count).map { i in
            ChatMessage(
                id: UUID(),
                role: i % 2 == 0 ? .user : .assistant,
                content: .text("Message \(i)"),
                timestamp: Date()
            )
        }
    }
}
