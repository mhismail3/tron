import XCTest
@testable import TronMobile

final class SessionEventTypeTests: XCTestCase {
    func testServerDurableCatalogMatchesTheFifteenEventContract() {
        XCTAssertEqual(
            SessionEventType.serverDurableCases.map(\.rawValue),
            [
                "session.start",
                "session.end",
                "session.fork",
                "session.model_changed",
                "session.reasoning_changed",
                "message.user",
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
}
