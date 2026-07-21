import XCTest
@testable import TronMobile

final class SessionEventTypeTests: XCTestCase {
    func testServerDurableCatalogMatchesTheThirteenEventContract() {
        XCTAssertEqual(
            SessionEventType.serverDurableCases.map(\.rawValue),
            [
                "session.start",
                "session.end",
                "session.fork",
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
