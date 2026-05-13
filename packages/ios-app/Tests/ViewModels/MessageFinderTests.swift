import XCTest
@testable import TronMobile

/// Tests for MessageFinder — typed message search utility
@MainActor
final class MessageFinderTests: XCTestCase {

    // MARK: - Helpers

    private func makeCapabilityInvocationMessage(invocationId: String, contractId: String = "filesystem::read_file") -> ChatMessage {
        ChatMessage(role: .assistant, content: .capabilityInvocation(testCapabilityInvocation(
            id: invocationId,
            status: .success,
            identity: testCapabilityIdentity(contractId: contractId, functionId: contractId)
        )))
    }

    private func makeCapabilityResultMessage(invocationId: String) -> ChatMessage {
        ChatMessage(role: .user, content: .capabilityResult(testCapabilityResult(id: invocationId)))
    }

    private func makeSubagentMessage(invocationId: String, subagentSessionId: String = "sub-sess") -> ChatMessage {
        ChatMessage(role: .assistant, content: .subagent(SubagentToolData(
            invocationId: invocationId, subagentSessionId: subagentSessionId,
            task: "Do work", model: nil, status: .completed, currentTurn: 1
        )))
    }

    private func makeAskUserQuestionMessage(invocationId: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .askUserQuestion(AskUserQuestionToolData(
            invocationId: invocationId,
            params: AskUserQuestionParams(questions: [
                AskUserQuestion(id: "q1", question: "Pick one", options: [
                    AskUserQuestionOption(label: "A", value: nil, description: nil)
                ], mode: .single, allowOther: nil, otherPlaceholder: nil)
            ], context: nil),
            answers: [:],
            status: .pending
        )))
    }

    private func makeEngineApprovalMessage(invocationId: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .engineApproval(EngineApprovalToolData(
            invocationId: invocationId,
            params: EngineApprovalParams(action: "Delete file", reason: "Cleanup", riskLevel: .low),
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

    func testHasToolMessageForToolUse() {
        XCTAssertTrue(MessageFinder.hasCapabilityInvocationMessage(invocationId: "tc-1", in: [makeCapabilityInvocationMessage(invocationId: "tc-1")]))
    }

    func testHasToolMessageForToolResult() {
        XCTAssertTrue(MessageFinder.hasCapabilityInvocationMessage(invocationId: "tc-1", in: [makeCapabilityResultMessage(invocationId: "tc-1")]))
    }

    func testHasToolMessageForSubagent() {
        XCTAssertTrue(MessageFinder.hasCapabilityInvocationMessage(invocationId: "tc-1", in: [makeSubagentMessage(invocationId: "tc-1")]))
    }

    func testHasToolMessageForAskUserQuestion() {
        XCTAssertTrue(MessageFinder.hasCapabilityInvocationMessage(invocationId: "tc-1", in: [makeAskUserQuestionMessage(invocationId: "tc-1")]))
    }

    func testHasToolMessageForEngineApproval() {
        XCTAssertTrue(MessageFinder.hasCapabilityInvocationMessage(invocationId: "tc-1", in: [makeEngineApprovalMessage(invocationId: "tc-1")]))
    }

    func testHasToolMessageReturnsFalseForText() {
        XCTAssertFalse(MessageFinder.hasCapabilityInvocationMessage(invocationId: "tc-1", in: [makeTextMessage()]))
    }

    func testHasToolMessageReturnsFalseForWrongId() {
        XCTAssertFalse(MessageFinder.hasCapabilityInvocationMessage(invocationId: "tc-wrong", in: [makeCapabilityInvocationMessage(invocationId: "tc-1")]))
    }

    func testHasToolMessageEmptyArray() {
        XCTAssertFalse(MessageFinder.hasCapabilityInvocationMessage(invocationId: "tc-1", in: []))
    }

    // MARK: - lastIndexOfAskUserQuestion

    func testLastIndexOfAskUserQuestionFound() {
        let messages = [makeAskUserQuestionMessage(invocationId: "tc-1")]
        XCTAssertEqual(MessageFinder.lastIndexOfAskUserQuestion(invocationId: "tc-1", in: messages), 0)
    }

    func testLastIndexOfAskUserQuestionNotFound() {
        XCTAssertNil(MessageFinder.lastIndexOfAskUserQuestion(invocationId: "tc-x", in: [makeTextMessage()]))
    }

    // MARK: - lastIndexOfEngineApproval

    func testLastIndexOfEngineApprovalFound() {
        let messages = [makeEngineApprovalMessage(invocationId: "tc-1")]
        XCTAssertEqual(MessageFinder.lastIndexOfEngineApproval(invocationId: "tc-1", in: messages), 0)
    }

    func testLastIndexOfEngineApprovalNotFound() {
        XCTAssertNil(MessageFinder.lastIndexOfEngineApproval(invocationId: "tc-x", in: [makeTextMessage()]))
    }

    // MARK: - indexBySubagentSessionId

    func testIndexBySubagentSessionIdFound() {
        let messages = [makeSubagentMessage(invocationId: "tc-1", subagentSessionId: "sub-abc")]
        XCTAssertEqual(MessageFinder.indexBySubagentSessionId("sub-abc", in: messages), 0)
    }

    func testIndexBySubagentSessionIdNotFound() {
        XCTAssertNil(MessageFinder.indexBySubagentSessionId("sub-x", in: [makeTextMessage()]))
    }

    // MARK: - indexOfSpawnSubagentTool

    func testIndexOfSpawnSubagentToolMatchesBothIdAndContract() {
        let messages = [makeCapabilityInvocationMessage(invocationId: "tc-1", contractId: "agent::spawn_subagent")]
        XCTAssertEqual(MessageFinder.indexOfSpawnSubagentTool(invocationId: "tc-1", in: messages), 0)
    }

    func testIndexOfSpawnSubagentToolWrongContractReturnsNil() {
        let messages = [makeCapabilityInvocationMessage(invocationId: "tc-1", contractId: "filesystem::read_file")]
        XCTAssertNil(MessageFinder.indexOfSpawnSubagentTool(invocationId: "tc-1", in: messages))
    }

    func testIndexOfSpawnSubagentToolWrongIdReturnsNil() {
        let messages = [makeCapabilityInvocationMessage(invocationId: "tc-wrong", contractId: "agent::spawn_subagent")]
        XCTAssertNil(MessageFinder.indexOfSpawnSubagentTool(invocationId: "tc-1", in: messages))
    }
}
