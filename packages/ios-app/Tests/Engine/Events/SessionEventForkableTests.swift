import XCTest
@testable import TronMobile

final class SessionEventForkableTests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
        type: String,
        payload: [String: AnyCodable] = [:]
    ) -> SessionEvent {
        SessionEvent(
            id: "evt-\(UUID().uuidString)",
            parentId: nil,
            sessionId: "session-1",
            workspaceId: "/test",
            type: type,
            timestamp: "2024-01-01T00:00:00Z",
            sequence: 1,
            payload: payload
        )
    }

    // MARK: - messageUser (always forkable)

    func testMessageUser_withStringContent_isForkable() {
        let event = makeEvent(type: "message.user", payload: [
            "content": AnyCodable("Hello world"),
        ])
        XCTAssertTrue(event.isForkable)
    }

    func testMessageUser_withEmptyContent_isForkable() {
        let event = makeEvent(type: "message.user", payload: [
            "content": AnyCodable(""),
        ])
        XCTAssertTrue(event.isForkable)
    }

    func testMessageUser_withNoPayload_isForkable() {
        let event = makeEvent(type: "message.user")
        XCTAssertTrue(event.isForkable)
    }

    // MARK: - messageAssistant (always forkable — fork point selection is handled at the UI layer)

    func testAssistant_textOnlyContentArray_isForkable() {
        let event = makeEvent(type: "message.assistant", payload: [
            "content": AnyCodable([
                ["type": "text", "text": "Here is my response"],
            ]),
            "stopReason": AnyCodable("end_turn"),
        ])
        XCTAssertTrue(event.isForkable)
    }

    func testAssistant_stringContent_historicalFormat_isForkable() {
        let event = makeEvent(type: "message.assistant", payload: [
            "content": AnyCodable("Plain string response"),
            "stopReason": AnyCodable("end_turn"),
        ])
        XCTAssertTrue(event.isForkable)
    }

    func testAssistant_endTurnStopReason_isForkable() {
        let event = makeEvent(type: "message.assistant", payload: [
            "content": AnyCodable([
                ["type": "text", "text": "Done"],
            ]),
            "stopReason": AnyCodable("end_turn"),
        ])
        XCTAssertTrue(event.isForkable)
    }

    func testAssistant_emptyContentArray_isForkable() {
        let event = makeEvent(type: "message.assistant", payload: [
            "content": AnyCodable([Any]()),
            "stopReason": AnyCodable("end_turn"),
        ])
        XCTAssertTrue(event.isForkable)
    }

    func testAssistant_missingContent_isForkable() {
        let event = makeEvent(type: "message.assistant", payload: [
            "stopReason": AnyCodable("end_turn"),
        ])
        XCTAssertTrue(event.isForkable)
    }

    func testAssistant_interruptedWithTextOnly_isForkable() {
        let event = makeEvent(type: "message.assistant", payload: [
            "content": AnyCodable([
                ["type": "text", "text": "I was interrupted"],
            ]),
            "stopReason": AnyCodable("interrupted"),
        ])
        XCTAssertTrue(event.isForkable)
    }

    func testAssistant_withCapabilityInvocationBlock_isForkable() {
        let event = makeEvent(type: "message.assistant", payload: [
            "content": AnyCodable([
                ["type": "text", "text": "Let me run that"],
                ["type": "capability_invocation", "id": "toolu_123", "name": "execute", "input": ["command": "ls"]],
            ]),
            "stopReason": AnyCodable("capability_invocation"),
        ])
        XCTAssertTrue(event.isForkable)
    }

    func testAssistant_stopReasonCapabilityInvocation_isForkable() {
        let event = makeEvent(type: "message.assistant", payload: [
            "content": AnyCodable([
                ["type": "capability_invocation", "id": "toolu_456", "name": "execute", "input": ["path": "/tmp"]],
            ]),
            "stopReason": AnyCodable("capability_invocation"),
        ])
        XCTAssertTrue(event.isForkable)
    }

    func testAssistant_interruptedWithCapabilityInvocationInContent_isForkable() {
        let event = makeEvent(type: "message.assistant", payload: [
            "content": AnyCodable([
                ["type": "text", "text": "Running..."],
                ["type": "capability_invocation", "id": "toolu_789", "name": "execute", "input": ["command": "test"]],
            ]),
            "stopReason": AnyCodable("interrupted"),
        ])
        XCTAssertTrue(event.isForkable)
    }

    func testAssistant_mixedContentWithCapabilityInvocation_isForkable() {
        let event = makeEvent(type: "message.assistant", payload: [
            "content": AnyCodable([
                ["type": "thinking", "thinking": "Let me think..."],
                ["type": "text", "text": "I'll check that file"],
                ["type": "capability_invocation", "id": "toolu_abc", "name": "execute", "input": ["path": "/etc"]],
            ]),
            "stopReason": AnyCodable("capability_invocation"),
        ])
        XCTAssertTrue(event.isForkable)
    }

    func testAssistant_stopReasonCapabilityInvocation_noContent_isForkable() {
        let event = makeEvent(type: "message.assistant", payload: [
            "stopReason": AnyCodable("capability_invocation"),
        ])
        XCTAssertTrue(event.isForkable)
    }

    // MARK: - Non-forkable event types

    func testCapabilityInvocation_isNotForkable() {
        let event = makeEvent(type: "capability.invocation.started", payload: [
            "modelPrimitiveName": AnyCodable("execute"),
            "arguments": AnyCodable(["command": "ls"]),
        ])
        XCTAssertFalse(event.isForkable)
    }

    func testCapabilityInvocationResult_isNotForkable() {
        let event = makeEvent(type: "capability.invocation.completed", payload: [
            "content": AnyCodable("file1.txt\nfile2.txt"),
            "isError": AnyCodable(false),
        ])
        XCTAssertFalse(event.isForkable)
    }

    func testSessionStart_isNotForkable() {
        let event = makeEvent(type: "session.start", payload: [
            "model": AnyCodable("claude-sonnet-4"),
        ])
        XCTAssertFalse(event.isForkable)
    }

    func testSessionFork_isNotForkable() {
        let event = makeEvent(type: "session.fork", payload: [
            "sourceSessionId": AnyCodable("sess-old"),
            "sourceEventId": AnyCodable("evt-old"),
        ])
        XCTAssertFalse(event.isForkable)
    }

    func testStreamTurnStart_isNotForkable() {
        let event = makeEvent(type: "stream.turn_start", payload: [
            "turn": AnyCodable(1),
        ])
        XCTAssertFalse(event.isForkable)
    }

    func testStreamTextDelta_isNotForkable() {
        let event = makeEvent(type: "stream.text_delta", payload: [
            "delta": AnyCodable("Hello"),
        ])
        XCTAssertFalse(event.isForkable)
    }

    func testCompactBoundary_isNotForkable() {
        let event = makeEvent(type: "compact.boundary")
        XCTAssertFalse(event.isForkable)
    }

    func testErrorAgent_isNotForkable() {
        let event = makeEvent(type: "error.agent", payload: [
            "error": AnyCodable("Something went wrong"),
        ])
        XCTAssertFalse(event.isForkable)
    }

    func testConfigModelSwitch_isNotForkable() {
        let event = makeEvent(type: "config.model_switch", payload: [
            "model": AnyCodable("claude-opus-4"),
        ])
        XCTAssertFalse(event.isForkable)
    }

    func testContextCleared_isNotForkable() {
        let event = makeEvent(type: "context.cleared")
        XCTAssertFalse(event.isForkable)
    }

    func testUnknownEventType_isNotForkable() {
        let event = makeEvent(type: "some.future.event", payload: [
            "data": AnyCodable("whatever"),
        ])
        XCTAssertFalse(event.isForkable)
    }
}
