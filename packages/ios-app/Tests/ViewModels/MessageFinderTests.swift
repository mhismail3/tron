import XCTest
@testable import TronMobile

/// Tests for MessageFinder — typed message search utility
@MainActor
final class MessageFinderTests: XCTestCase {

    // MARK: - Helpers

    private func makeToolUseMessage(toolCallId: String, toolName: String = "TestTool") -> ChatMessage {
        ChatMessage(role: .assistant, content: .toolUse(ToolUseData(
            toolName: toolName, toolCallId: toolCallId, arguments: "{}", status: .success
        )))
    }

    private func makeToolResultMessage(toolCallId: String) -> ChatMessage {
        ChatMessage(role: .user, content: .toolResult(ToolResultData(
            toolCallId: toolCallId, content: "ok", isError: false
        )))
    }

    private func makeSubagentMessage(toolCallId: String, subagentSessionId: String = "sub-sess") -> ChatMessage {
        ChatMessage(role: .assistant, content: .subagent(SubagentToolData(
            toolCallId: toolCallId, subagentSessionId: subagentSessionId,
            task: "Do work", model: nil, status: .completed, currentTurn: 1
        )))
    }

    private func makeAskUserQuestionMessage(toolCallId: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .askUserQuestion(AskUserQuestionToolData(
            toolCallId: toolCallId,
            params: AskUserQuestionParams(questions: [
                AskUserQuestion(id: "q1", question: "Pick one", options: [
                    AskUserQuestionOption(label: "A", value: nil, description: nil)
                ], mode: .single, allowOther: nil, otherPlaceholder: nil)
            ], context: nil),
            answers: [:],
            status: .pending
        )))
    }

    private func makeGetConfirmationMessage(toolCallId: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .getConfirmation(GetConfirmationToolData(
            toolCallId: toolCallId,
            params: GetConfirmationParams(action: "Delete file", reason: "Cleanup", riskLevel: .low),
            status: .pending
        )))
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

    // MARK: - lastIndexOfToolUse

    func testLastIndexOfToolUseReturnsLast() {
        let messages = [
            makeToolUseMessage(toolCallId: "tc-1"),
            makeTextMessage(),
            makeToolUseMessage(toolCallId: "tc-1"),
        ]
        XCTAssertEqual(MessageFinder.lastIndexOfToolUse(toolCallId: "tc-1", in: messages), 2)
    }

    func testLastIndexOfToolUseNotFound() {
        let messages = [makeTextMessage()]
        XCTAssertNil(MessageFinder.lastIndexOfToolUse(toolCallId: "tc-missing", in: messages))
    }

    // MARK: - lastIndexOfToolResult

    func testLastIndexOfToolResultReturnsLast() {
        let messages = [
            makeToolResultMessage(toolCallId: "tc-1"),
            makeToolResultMessage(toolCallId: "tc-1"),
        ]
        XCTAssertEqual(MessageFinder.lastIndexOfToolResult(toolCallId: "tc-1", in: messages), 1)
    }

    func testLastIndexOfToolResultNotFound() {
        XCTAssertNil(MessageFinder.lastIndexOfToolResult(toolCallId: "tc-x", in: [makeTextMessage()]))
    }

    // MARK: - hasToolMessage

    func testHasToolMessageForToolUse() {
        XCTAssertTrue(MessageFinder.hasToolMessage(toolCallId: "tc-1", in: [makeToolUseMessage(toolCallId: "tc-1")]))
    }

    func testHasToolMessageForToolResult() {
        XCTAssertTrue(MessageFinder.hasToolMessage(toolCallId: "tc-1", in: [makeToolResultMessage(toolCallId: "tc-1")]))
    }

    func testHasToolMessageForSubagent() {
        XCTAssertTrue(MessageFinder.hasToolMessage(toolCallId: "tc-1", in: [makeSubagentMessage(toolCallId: "tc-1")]))
    }

    func testHasToolMessageForAskUserQuestion() {
        XCTAssertTrue(MessageFinder.hasToolMessage(toolCallId: "tc-1", in: [makeAskUserQuestionMessage(toolCallId: "tc-1")]))
    }

    func testHasToolMessageForGetConfirmation() {
        XCTAssertTrue(MessageFinder.hasToolMessage(toolCallId: "tc-1", in: [makeGetConfirmationMessage(toolCallId: "tc-1")]))
    }

    func testHasToolMessageReturnsFalseForText() {
        XCTAssertFalse(MessageFinder.hasToolMessage(toolCallId: "tc-1", in: [makeTextMessage()]))
    }

    func testHasToolMessageReturnsFalseForWrongId() {
        XCTAssertFalse(MessageFinder.hasToolMessage(toolCallId: "tc-wrong", in: [makeToolUseMessage(toolCallId: "tc-1")]))
    }

    func testHasToolMessageEmptyArray() {
        XCTAssertFalse(MessageFinder.hasToolMessage(toolCallId: "tc-1", in: []))
    }

    // MARK: - lastIndexOfAskUserQuestion

    func testLastIndexOfAskUserQuestionFound() {
        let messages = [makeAskUserQuestionMessage(toolCallId: "tc-1")]
        XCTAssertEqual(MessageFinder.lastIndexOfAskUserQuestion(toolCallId: "tc-1", in: messages), 0)
    }

    func testLastIndexOfAskUserQuestionNotFound() {
        XCTAssertNil(MessageFinder.lastIndexOfAskUserQuestion(toolCallId: "tc-x", in: [makeTextMessage()]))
    }

    // MARK: - lastIndexOfGetConfirmation

    func testLastIndexOfGetConfirmationFound() {
        let messages = [makeGetConfirmationMessage(toolCallId: "tc-1")]
        XCTAssertEqual(MessageFinder.lastIndexOfGetConfirmation(toolCallId: "tc-1", in: messages), 0)
    }

    func testLastIndexOfGetConfirmationNotFound() {
        XCTAssertNil(MessageFinder.lastIndexOfGetConfirmation(toolCallId: "tc-x", in: [makeTextMessage()]))
    }

    // MARK: - indexBySubagentSessionId

    func testIndexBySubagentSessionIdFound() {
        let messages = [makeSubagentMessage(toolCallId: "tc-1", subagentSessionId: "sub-abc")]
        XCTAssertEqual(MessageFinder.indexBySubagentSessionId("sub-abc", in: messages), 0)
    }

    func testIndexBySubagentSessionIdNotFound() {
        XCTAssertNil(MessageFinder.indexBySubagentSessionId("sub-x", in: [makeTextMessage()]))
    }

    // MARK: - indexOfSpawnSubagentTool

    func testIndexOfSpawnSubagentToolMatchesBothIdAndName() {
        let messages = [makeToolUseMessage(toolCallId: "tc-1", toolName: "SpawnSubagent")]
        XCTAssertEqual(MessageFinder.indexOfSpawnSubagentTool(toolCallId: "tc-1", in: messages), 0)
    }

    func testIndexOfSpawnSubagentToolWrongToolNameReturnsNil() {
        let messages = [makeToolUseMessage(toolCallId: "tc-1", toolName: "OtherTool")]
        XCTAssertNil(MessageFinder.indexOfSpawnSubagentTool(toolCallId: "tc-1", in: messages))
    }

    func testIndexOfSpawnSubagentToolWrongIdReturnsNil() {
        let messages = [makeToolUseMessage(toolCallId: "tc-wrong", toolName: "SpawnSubagent")]
        XCTAssertNil(MessageFinder.indexOfSpawnSubagentTool(toolCallId: "tc-1", in: messages))
    }
}
