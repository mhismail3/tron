import XCTest
@testable import TronMobile

/// Tests for MessageFinder — typed message search utility
@MainActor
final class MessageFinderTests: XCTestCase {

    // MARK: - Helpers

    private func makeToolInvocationMessage(invocationId: String, toolName: String = "filesystem_read") -> ChatMessage {
        ChatMessage(role: .assistant, content: .toolInvocation(testToolInvocation(
            id: invocationId,
            status: .success,
            identity: testToolIdentity(toolName: toolName)
        )))
    }

    private func makeToolResultMessage(invocationId: String) -> ChatMessage {
        ChatMessage(role: .user, content: .toolResult(testToolResult(id: invocationId)))
    }

    private func makeTextMessage(text: String = "Hello", eventId: String? = nil) -> ChatMessage {
        ChatMessage(role: .user, content: .text(text), eventId: eventId)
    }

    // MARK: - indexById

    func testIndexByIdFound() {
        let target = ChatMessage(role: .user, content: .text("target"))
        let messages = [makeTextMessage(), target, makeTextMessage()]
        XCTAssertEqual(MessageFinder.indexById(target.id, in: messages), 1)
    }

    func testIndexByIdNotFound() {
        let messages = [makeTextMessage()]
        XCTAssertNil(MessageFinder.indexById(UUID(), in: messages))
    }

    func testIndexByIdEmptyArray() {
        XCTAssertNil(MessageFinder.indexById(UUID(), in: []))
    }

    // MARK: - indexByEventId

    func testIndexByEventIdFound() {
        let messages = [
            makeTextMessage(eventId: "evt-1"),
            makeTextMessage(eventId: "evt-2"),
        ]
        XCTAssertEqual(MessageFinder.indexByEventId("evt-2", in: messages), 1)
    }

    func testIndexByEventIdNotFound() {
        let messages = [makeTextMessage(eventId: "evt-1")]
        XCTAssertNil(MessageFinder.indexByEventId("evt-999", in: messages))
    }

    func testIndexByEventIdEmptyArray() {
        XCTAssertNil(MessageFinder.indexByEventId("evt-1", in: []))
    }

    // MARK: - lastIndexOfToolInvocation

    func testLastIndexOfToolInvocationReturnsLast() {
        let messages = [
            makeToolInvocationMessage(invocationId: "tc-1"),
            makeTextMessage(),
            makeToolInvocationMessage(invocationId: "tc-1"),
        ]
        XCTAssertEqual(MessageFinder.lastIndexOfToolInvocation(id: "tc-1", in: messages), 2)
    }

    func testLastIndexOfToolInvocationNotFound() {
        let messages = [makeTextMessage()]
        XCTAssertNil(MessageFinder.lastIndexOfToolInvocation(id: "tc-missing", in: messages))
    }

    // MARK: - lastIndexOfToolResult

    func testLastIndexOfToolResultReturnsLast() {
        let messages = [
            makeToolResultMessage(invocationId: "tc-1"),
            makeToolResultMessage(invocationId: "tc-1"),
        ]
        XCTAssertEqual(MessageFinder.lastIndexOfToolResult(id: "tc-1", in: messages), 1)
    }

    func testLastIndexOfToolResultNotFound() {
        XCTAssertNil(MessageFinder.lastIndexOfToolResult(id: "tc-x", in: [makeTextMessage()]))
    }

    // MARK: - hasToolInvocationMessage

    func testHasToolMessageForToolInvocation() {
        XCTAssertTrue(MessageFinder.hasToolInvocationMessage(invocationId: "tc-1", in: [makeToolInvocationMessage(invocationId: "tc-1")]))
    }

    func testHasToolMessageForToolResult() {
        XCTAssertTrue(MessageFinder.hasToolInvocationMessage(invocationId: "tc-1", in: [makeToolResultMessage(invocationId: "tc-1")]))
    }

    func testHasToolMessageReturnsFalseForText() {
        XCTAssertFalse(MessageFinder.hasToolInvocationMessage(invocationId: "tc-1", in: [makeTextMessage()]))
    }

    func testHasToolMessageReturnsFalseForWrongId() {
        XCTAssertFalse(MessageFinder.hasToolInvocationMessage(invocationId: "tc-wrong", in: [makeToolInvocationMessage(invocationId: "tc-1")]))
    }

    func testHasToolMessageEmptyArray() {
        XCTAssertFalse(MessageFinder.hasToolInvocationMessage(invocationId: "tc-1", in: []))
    }

}
