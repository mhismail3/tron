import XCTest
@testable import TronMobile

/// Tests for MessageFinder — typed message search utility
@MainActor
final class MessageFinderTests: XCTestCase {

    // MARK: - Helpers

    private func makeCapabilityInvocationMessage(invocationId: String, operationName: String = "file_read") -> ChatMessage {
        ChatMessage(role: .assistant, content: .capabilityInvocation(testCapabilityInvocation(
            id: invocationId,
            status: .success,
            identity: testCapabilityIdentity(operationName: operationName)
        )))
    }

    private func makeCapabilityResultMessage(invocationId: String) -> ChatMessage {
        ChatMessage(role: .user, content: .capabilityResult(testCapabilityResult(id: invocationId)))
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

    // MARK: - lastIndexOfCapabilityInvocation

    func testLastIndexOfCapabilityInvocationReturnsLast() {
        let messages = [
            makeCapabilityInvocationMessage(invocationId: "tc-1"),
            makeTextMessage(),
            makeCapabilityInvocationMessage(invocationId: "tc-1"),
        ]
        XCTAssertEqual(MessageFinder.lastIndexOfCapabilityInvocation(id: "tc-1", in: messages), 2)
    }

    func testLastIndexOfCapabilityInvocationNotFound() {
        let messages = [makeTextMessage()]
        XCTAssertNil(MessageFinder.lastIndexOfCapabilityInvocation(id: "tc-missing", in: messages))
    }

    // MARK: - lastIndexOfCapabilityResult

    func testLastIndexOfCapabilityResultReturnsLast() {
        let messages = [
            makeCapabilityResultMessage(invocationId: "tc-1"),
            makeCapabilityResultMessage(invocationId: "tc-1"),
        ]
        XCTAssertEqual(MessageFinder.lastIndexOfCapabilityResult(id: "tc-1", in: messages), 1)
    }

    func testLastIndexOfCapabilityResultNotFound() {
        XCTAssertNil(MessageFinder.lastIndexOfCapabilityResult(id: "tc-x", in: [makeTextMessage()]))
    }

    // MARK: - hasCapabilityInvocationMessage

    func testHasCapabilityMessageForCapabilityInvocation() {
        XCTAssertTrue(MessageFinder.hasCapabilityInvocationMessage(invocationId: "tc-1", in: [makeCapabilityInvocationMessage(invocationId: "tc-1")]))
    }

    func testHasCapabilityMessageForCapabilityResult() {
        XCTAssertTrue(MessageFinder.hasCapabilityInvocationMessage(invocationId: "tc-1", in: [makeCapabilityResultMessage(invocationId: "tc-1")]))
    }

    func testHasCapabilityMessageReturnsFalseForText() {
        XCTAssertFalse(MessageFinder.hasCapabilityInvocationMessage(invocationId: "tc-1", in: [makeTextMessage()]))
    }

    func testHasCapabilityMessageReturnsFalseForWrongId() {
        XCTAssertFalse(MessageFinder.hasCapabilityInvocationMessage(invocationId: "tc-wrong", in: [makeCapabilityInvocationMessage(invocationId: "tc-1")]))
    }

    func testHasCapabilityMessageEmptyArray() {
        XCTAssertFalse(MessageFinder.hasCapabilityInvocationMessage(invocationId: "tc-1", in: []))
    }

}
