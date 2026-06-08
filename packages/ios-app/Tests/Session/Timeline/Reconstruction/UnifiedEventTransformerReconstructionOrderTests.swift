import XCTest
@testable import TronMobile

final class UnifiedEventTransformerReconstructionOrderTests: XCTestCase {
    private func timestamp(_ offsetSeconds: TimeInterval = 0) -> String {
        let date = Date().addingTimeInterval(offsetSeconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func rawEvent(
        id: String,
        parentId: String? = nil,
        sessionId: String = "test-session",
        type: String,
        payload: [String: AnyCodable],
        timestamp: String,
        sequence: Int
    ) -> RawEvent {
        RawEvent(
            id: id,
            parentId: parentId,
            sessionId: sessionId,
            workspaceId: "/test/workspace",
            type: type,
            timestamp: timestamp,
            sequence: sequence,
            payload: payload
        )
    }

    func testPresortedReconstructionPreservesCrossSessionForkChainOrder() {
        let parentPrompt = rawEvent(
            id: "parent-prompt",
            sessionId: "parent-session",
            type: "message.user",
            payload: ["content": AnyCodable("parent prompt")],
            timestamp: timestamp(1),
            sequence: 10
        )
        let forkRoot = rawEvent(
            id: "fork-root",
            parentId: "parent-prompt",
            sessionId: "fork-session",
            type: "session.fork",
            payload: [
                "sourceSessionId": AnyCodable("parent-session"),
                "sourceEventId": AnyCodable("parent-prompt")
            ],
            timestamp: timestamp(2),
            sequence: 0
        )
        let forkPrompt = rawEvent(
            id: "fork-prompt",
            parentId: "fork-root",
            sessionId: "fork-session",
            type: "message.user",
            payload: ["content": AnyCodable("fork prompt")],
            timestamp: timestamp(3),
            sequence: 1
        )

        let state = UnifiedEventTransformer.reconstructSessionState(
            from: [parentPrompt, forkRoot, forkPrompt],
            presorted: true
        )

        XCTAssertEqual(state.messages.count, 2)
        if case .text(let firstText) = state.messages[0].content,
           case .text(let secondText) = state.messages[1].content {
            XCTAssertEqual(firstText, "parent prompt")
            XCTAssertEqual(secondText, "fork prompt")
        } else {
            XCTFail("Expected text messages for fork reconstruction")
        }
    }

    func testPresortedPersistedTransformationPreservesCrossSessionForkChainOrder() {
        let parentPrompt = rawEvent(
            id: "parent-prompt",
            sessionId: "parent-session",
            type: "message.user",
            payload: ["content": AnyCodable("parent prompt")],
            timestamp: timestamp(1),
            sequence: 10
        )
        let forkPrompt = rawEvent(
            id: "fork-prompt",
            parentId: "fork-root",
            sessionId: "fork-session",
            type: "message.user",
            payload: ["content": AnyCodable("fork prompt")],
            timestamp: timestamp(2),
            sequence: 1
        )

        let messages = UnifiedEventTransformer.transformPersistedEvents(
            [parentPrompt, forkPrompt],
            presorted: true
        )

        XCTAssertEqual(messages.count, 2)
        if case .text(let firstText) = messages[0].content,
           case .text(let secondText) = messages[1].content {
            XCTAssertEqual(firstText, "parent prompt")
            XCTAssertEqual(secondText, "fork prompt")
        } else {
            XCTFail("Expected text messages for fork transformation")
        }
    }

    func testTransformPersistedEventsPreservesEventIdsForDeepLinks() {
        let user = rawEvent(
            id: "user-event",
            type: "message.user",
            payload: ["content": AnyCodable("user prompt")],
            timestamp: timestamp(1),
            sequence: 1
        )
        let assistant = rawEvent(
            id: "assistant-event",
            type: "message.assistant",
            payload: [
                "content": AnyCodable([["type": "text", "text": "assistant response"] as [String: Any]]),
                "turn": AnyCodable(1),
                "model": AnyCodable("gpt-5.5"),
                "stopReason": AnyCodable("end_turn")
            ],
            timestamp: timestamp(2),
            sequence: 2
        )

        let messages = UnifiedEventTransformer.transformPersistedEvents([user, assistant])

        XCTAssertEqual(messages.map(\.eventId), ["user-event", "assistant-event"])
    }
}
