import XCTest
@testable import TronMobile

@MainActor
final class MemoryCoordinatorTests: XCTestCase {

    private var coordinator: MemoryCoordinator!
    private var mockContext: MockMemoryContext!

    override func setUp() async throws {
        coordinator = MemoryCoordinator()
        mockContext = MockMemoryContext()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - handleMemoryUpdating Tests

    func testMemoryUpdatingSetsIsRetaining() {
        let result = MemoryUpdatingPlugin.Result()
        coordinator.handleMemoryUpdating(result, context: mockContext)

        XCTAssertTrue(mockContext.isRetaining)
    }

    func testMemoryUpdatingFinalizesStreaming() {
        let result = MemoryUpdatingPlugin.Result()
        coordinator.handleMemoryUpdating(result, context: mockContext)

        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testMemoryUpdatingAppendsInProgressMessage() {
        let result = MemoryUpdatingPlugin.Result()
        coordinator.handleMemoryUpdating(result, context: mockContext)

        XCTAssertEqual(mockContext.messages.count, 1)
        if case .systemEvent(.memoryRetainInProgress) = mockContext.messages[0].content {
            // correct
        } else {
            XCTFail("Expected memoryRetainInProgress content")
        }
    }

    func testMemoryUpdatingTracksInProgressId() {
        let result = MemoryUpdatingPlugin.Result()
        coordinator.handleMemoryUpdating(result, context: mockContext)

        XCTAssertNotNil(mockContext.memoryRetainInProgressMessageId)
        XCTAssertEqual(mockContext.memoryRetainInProgressMessageId, mockContext.messages[0].id)
    }

    // MARK: - handleMemoryUpdated Tests (with title)

    func testMemoryUpdatedClearsIsRetaining() {
        mockContext.isRetaining = true

        let result = MemoryUpdatedPlugin.Result(title: "Session Summary", summary: "A summary")
        coordinator.handleMemoryUpdated(result, context: mockContext)

        XCTAssertFalse(mockContext.isRetaining)
    }

    func testMemoryUpdatedFinalizesStreaming() {
        let result = MemoryUpdatedPlugin.Result(title: "Test", summary: nil)
        coordinator.handleMemoryUpdated(result, context: mockContext)

        XCTAssertTrue(mockContext.flushPendingTextUpdatesCalled)
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testMemoryUpdatedWithTitleMutatesInPlace() {
        let inProgressMsg = ChatMessage.memoryRetainInProgress()
        mockContext.appendToMessages(inProgressMsg)
        mockContext.memoryRetainInProgressMessageId = inProgressMsg.id

        let result = MemoryUpdatedPlugin.Result(title: "My Memory", summary: "A summary")
        coordinator.handleMemoryUpdated(result, context: mockContext)

        XCTAssertEqual(mockContext.messages.count, 1)
        if case .systemEvent(.memoryRetained(let title, _)) = mockContext.messages[0].content {
            XCTAssertEqual(title, "My Memory")
        } else {
            XCTFail("Expected memoryRetained content")
        }
        XCTAssertNil(mockContext.memoryRetainInProgressMessageId)
    }

    func testMemoryUpdatedWithTitleAppendsWhenNoInProgress() {
        let result = MemoryUpdatedPlugin.Result(title: "My Memory", summary: nil)
        coordinator.handleMemoryUpdated(result, context: mockContext)

        XCTAssertEqual(mockContext.messages.count, 1)
        if case .systemEvent(.memoryRetained(let title, _)) = mockContext.messages[0].content {
            XCTAssertEqual(title, "My Memory")
        } else {
            XCTFail("Expected memoryRetained content")
        }
    }

    // MARK: - handleMemoryUpdated Tests (nothing new)

    func testMemoryUpdatedNothingNewMutatesInPlace() {
        let inProgressMsg = ChatMessage.memoryRetainInProgress()
        mockContext.appendToMessages(inProgressMsg)
        mockContext.memoryRetainInProgressMessageId = inProgressMsg.id

        let result = MemoryUpdatedPlugin.Result(title: nil, summary: nil)
        coordinator.handleMemoryUpdated(result, context: mockContext)

        XCTAssertEqual(mockContext.messages.count, 1)
        if case .systemEvent(.memoryRetainedNothingNew) = mockContext.messages[0].content {
            // correct
        } else {
            XCTFail("Expected memoryRetainedNothingNew content")
        }
        XCTAssertNil(mockContext.memoryRetainInProgressMessageId)
    }

    func testMemoryUpdatedNothingNewAppendsWhenNoInProgress() {
        let result = MemoryUpdatedPlugin.Result(title: nil, summary: nil)
        coordinator.handleMemoryUpdated(result, context: mockContext)

        XCTAssertEqual(mockContext.messages.count, 1)
        if case .systemEvent(.memoryRetainedNothingNew) = mockContext.messages[0].content {
            // correct
        } else {
            XCTFail("Expected memoryRetainedNothingNew content")
        }
    }
}

// MARK: - Mock Context

@MainActor
final class MockMemoryContext: MemoryContext {
    var isRetaining = false
    var memoryRetainInProgressMessageId: UUID?
    var messages: [ChatMessage] = []
    let messageIndex = MessageIndex()

    var flushPendingTextUpdatesCalled = false
    var finalizeStreamingMessageCalled = false
    var resetStreamingManagerCalled = false

    func flushPendingTextUpdates() {
        flushPendingTextUpdatesCalled = true
    }

    func finalizeStreamingMessage() {
        finalizeStreamingMessageCalled = true
    }

    func resetStreamingManager() {
        resetStreamingManagerCalled = true
    }

    // MARK: - LoggingContext

    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
    func showError(_ message: String) {}
}
