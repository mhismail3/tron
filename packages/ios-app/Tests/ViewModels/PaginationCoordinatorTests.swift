import XCTest
@testable import TronMobile

// MARK: - Mock Context

@MainActor
final class MockPaginationContext: PaginationContext {
    var messages: [ChatMessage] = []
    var allReconstructedMessages: [ChatMessage] = []
    var hasMoreMessages: Bool = false
    var isLoadingMoreMessages: Bool = false
    var displayedMessageCount: Int = 0
    var hasInitiallyLoaded: Bool = false
    var isProcessing: Bool = false

    var reconstructedState: ReconstructedState?
    var reconstructedStateError: Error?

    var logMessages: [String] = []

    func logDebug(_ message: String) {
        logMessages.append("[DEBUG] \(message)")
    }

    func logInfo(_ message: String) {
        logMessages.append("[INFO] \(message)")
    }

    func logWarning(_ message: String) {
        logMessages.append("[WARNING] \(message)")
    }

    func logError(_ message: String) {
        logMessages.append("[ERROR] \(message)")
    }

    func getReconstructedState() throws -> ReconstructedState {
        if let error = reconstructedStateError {
            throw error
        }
        guard let state = reconstructedState else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "No state configured"])
        }
        return state
    }
}

// MARK: - Tests

@MainActor
final class PaginationCoordinatorTests: XCTestCase {

    var coordinator: PaginationCoordinator!
    var mockContext: MockPaginationContext!

    override func setUp() {
        super.setUp()
        coordinator = PaginationCoordinator()
        mockContext = MockPaginationContext()
    }

    override func tearDown() {
        coordinator = nil
        mockContext = nil
        super.tearDown()
    }

    // MARK: - loadMoreMessages Tests

    func test_loadMoreMessages_whenHasNoMore_doesNotLoad() {
        // Given
        mockContext.hasMoreMessages = false
        mockContext.allReconstructedMessages = createTestMessages(count: 50)

        // When
        coordinator.loadMoreMessages(context: mockContext)

        // Then
        XCTAssertEqual(mockContext.displayedMessageCount, 0)
        XCTAssertFalse(mockContext.isLoadingMoreMessages)
    }

    func test_loadMoreMessages_whenAlreadyLoading_doesNotLoadAgain() {
        // Given
        mockContext.hasMoreMessages = true
        mockContext.isLoadingMoreMessages = true
        mockContext.allReconstructedMessages = createTestMessages(count: 50)

        // When
        coordinator.loadMoreMessages(context: mockContext)

        // Then
        XCTAssertEqual(mockContext.displayedMessageCount, 0)
        XCTAssertTrue(mockContext.isLoadingMoreMessages) // Still true, unchanged
    }

    func test_loadMoreMessages_loadsNextBatch() {
        // Given
        mockContext.hasMoreMessages = true
        mockContext.isLoadingMoreMessages = false
        mockContext.allReconstructedMessages = createTestMessages(count: 100)
        mockContext.displayedMessageCount = 25

        // When
        coordinator.loadMoreMessages(context: mockContext)

        // Then - should load additionalMessageBatchSize (25) more
        XCTAssertEqual(mockContext.displayedMessageCount, 50)
        XCTAssertFalse(mockContext.isLoadingMoreMessages)
        XCTAssertTrue(mockContext.hasMoreMessages) // Still more to load
    }

    func test_loadMoreMessages_loadsRemainingWhenLessThanBatchSize() {
        // Given
        mockContext.hasMoreMessages = true
        mockContext.isLoadingMoreMessages = false
        mockContext.allReconstructedMessages = createTestMessages(count: 30)
        mockContext.displayedMessageCount = 25

        // When
        coordinator.loadMoreMessages(context: mockContext)

        // Then - should load remaining 5
        XCTAssertEqual(mockContext.displayedMessageCount, 30)
        XCTAssertFalse(mockContext.isLoadingMoreMessages)
        XCTAssertFalse(mockContext.hasMoreMessages) // No more to load
    }

    func test_loadMoreMessages_setsHasMoreToFalseWhenAllLoaded() {
        // Given
        mockContext.hasMoreMessages = true
        mockContext.isLoadingMoreMessages = false
        mockContext.allReconstructedMessages = createTestMessages(count: 50)
        mockContext.displayedMessageCount = 25

        // When
        coordinator.loadMoreMessages(context: mockContext)

        // Then
        XCTAssertEqual(mockContext.displayedMessageCount, 50)
        XCTAssertFalse(mockContext.hasMoreMessages)
    }

    // MARK: - appendMessage Tests

    func test_appendMessage_addsToEnd() {
        // Given
        mockContext.messages = createTestMessages(count: 5)
        let newMessage = ChatMessage(role: .assistant, content: .text("New message"))

        // When
        coordinator.appendMessage(newMessage, context: mockContext)

        // Then
        XCTAssertEqual(mockContext.messages.count, 6)
        XCTAssertEqual(mockContext.messages.last?.id, newMessage.id)
    }

    // MARK: - findMessage Tests

    func test_findMessage_byId_returnsCorrectIndex() {
        // Given
        let messages = createTestMessages(count: 10)
        mockContext.messages = messages
        let targetId = messages[5].id

        // When
        let index = coordinator.findMessage(byId: targetId, in: mockContext)

        // Then
        XCTAssertEqual(index, 5)
    }

    func test_findMessage_byId_returnsNilWhenNotFound() {
        // Given
        mockContext.messages = createTestMessages(count: 10)
        let unknownId = UUID()

        // When
        let index = coordinator.findMessage(byId: unknownId, in: mockContext)

        // Then
        XCTAssertNil(index)
    }

    func test_findMessage_byEventId_returnsCorrectIndex() {
        // Given
        var messages = createTestMessages(count: 10)
        messages[7] = ChatMessage(
            id: messages[7].id,
            role: .assistant,
            content: .text("Test"),
            eventId: "evt_12345"
        )
        mockContext.messages = messages

        // When
        let index = coordinator.findMessage(byEventId: "evt_12345", in: mockContext)

        // Then
        XCTAssertEqual(index, 7)
    }

    func test_findMessage_byEventId_returnsNilWhenNotFound() {
        // Given
        mockContext.messages = createTestMessages(count: 10)

        // When
        let index = coordinator.findMessage(byEventId: "evt_unknown", in: mockContext)

        // Then
        XCTAssertNil(index)
    }

    // MARK: - Helpers

    private func createTestMessages(count: Int) -> [ChatMessage] {
        (0..<count).map { i in
            ChatMessage(role: .user, content: .text("Message \(i)"))
        }
    }
}
