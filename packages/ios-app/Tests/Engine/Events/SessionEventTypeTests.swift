import XCTest
@testable import TronMobile

final class SessionEventTypeTests: XCTestCase {
    func testServerDurableCatalogIncludesTypedAgentMessages() {
        XCTAssertEqual(
            SessionEventType.serverDurableCases.map(\.rawValue),
            [
                "session.start",
                "session.end",
                "session.fork",
                "session.model_changed",
                "session.reasoning_changed",
                "message.user",
                "message.agent",
                "message.assistant",
                "model.provider_request",
                "message.deleted",
                "tool.invocation.started",
                "tool.invocation.completed",
                "stream.turn_start",
                "stream.turn_end",
                "compact.boundary",
                "turn.failed"
            ]
        )
    }

    func testCompletedThinkingIsClientLocal() {
        XCTAssertFalse(SessionEventType.serverDurableCases.contains(.streamThinkingComplete))
    }

    func testAgentMessagesAreAuditRowsRatherThanUserForkPoints() {
        let event = SessionEvent(
            id: "event-agent",
            parentId: nil,
            sessionId: "session-agent",
            workspaceId: "/workspace",
            type: SessionEventType.messageAgent.rawValue,
            timestamp: "2026-08-11T00:00:00Z",
            sequence: 1,
            payload: [:]
        )
        XCTAssertFalse(event.isForkable)
    }
}
