import XCTest
@testable import TronMobile

final class AgentMessageTimelineTests: UnifiedEventTransformerTestCase {
    func testSingleEventProjectionPreservesDurableEventIdentityForLiveDeduplication() throws {
        let event = rawEvent(
            id: "event-agent-deduplication",
            type: SessionEventType.messageAgent.rawValue,
            payload: agentPayload(
                messageId: "message-deduplication",
                sourceAgentId: "agent-peer",
                sourceName: "Reviewer",
                kind: "update",
                authority: "peer",
                text: "The same durable event must not render twice."
            ),
            sequence: 1
        )

        let message = try XCTUnwrap(UnifiedEventTransformer.transformPersistedEvent(event))

        XCTAssertEqual(message.eventId, "event-agent-deduplication")
    }

    func testReconstructionKeepsAdjacentCoordinationMessagesDistinct() throws {
        let first = rawEvent(
            id: "event-agent-1",
            type: SessionEventType.messageAgent.rawValue,
            payload: agentPayload(
                messageId: "message-1",
                sourceAgentId: "agent-parent",
                sourceName: "Coordinator",
                kind: "instruction",
                authority: "owner",
                text: "Inspect the parser."
            ),
            sequence: 1
        )
        let second = rawEvent(
            id: "event-agent-2",
            type: SessionEventType.messageAgent.rawValue,
            payload: agentPayload(
                messageId: "message-2",
                sourceAgentId: "agent-peer",
                sourceName: nil,
                kind: "question",
                authority: "peer",
                text: "Which module owns it?",
                assignmentId: "assignment-2",
                replyTo: "message-1"
            ),
            sequence: 2
        )

        let state = UnifiedEventTransformer.reconstructSessionState(from: [first, second])

        XCTAssertEqual(state.messages.count, 2)
        XCTAssertEqual(state.messages.map(\.role), [.agent, .agent])
        XCTAssertEqual(state.messages.map(\.eventId), ["event-agent-1", "event-agent-2"])
        XCTAssertEqual(state.messages[0].agentMessage?.sourceName, "Coordinator")
        XCTAssertEqual(state.messages[1].agentMessage?.assignmentId, "assignment-2")
        XCTAssertEqual(state.messages[1].agentMessage?.replyTo, "message-1")
        XCTAssertFalse(state.messages[0].canBeDeleted)
        XCTAssertFalse(state.messages[1].canBeDeleted)
    }

    func testMalformedCoordinationEnvelopeFailsClosedWithoutDroppingNeighbors() {
        let malformed = rawEvent(
            id: "event-agent-malformed",
            type: SessionEventType.messageAgent.rawValue,
            payload: [
                "content": AnyCodable([
                    "messageId": "missing-authority",
                    "sourceAgentId": "agent-peer",
                    "kind": "information",
                    "text": "Incomplete provenance",
                ])
            ],
            sequence: 1
        )
        let user = rawEvent(
            id: "event-user",
            type: SessionEventType.messageUser.rawValue,
            payload: ["content": AnyCodable("Visible user message")],
            sequence: 2
        )

        let messages = UnifiedEventTransformer.transformPersistedEvents([malformed, user])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .user)
    }

    private func agentPayload(
        messageId: String,
        sourceAgentId: String,
        sourceName: String?,
        kind: String,
        authority: String,
        text: String,
        assignmentId: String? = nil,
        replyTo: String? = nil
    ) -> [String: AnyCodable] {
        var content: [String: Any] = [
            "messageId": messageId,
            "sourceAgentId": sourceAgentId,
            "kind": kind,
            "authority": authority,
            "text": text,
        ]
        content["sourceName"] = sourceName
        content["assignmentId"] = assignmentId
        content["replyTo"] = replyTo
        return ["content": AnyCodable(content)]
    }
}
