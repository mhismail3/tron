import XCTest
@testable import TronMobile

final class SessionEventSummaryTests: XCTestCase {

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

    // MARK: - Turn Failed

    func testTurnFailed_withError_showsError() {
        let event = makeEvent(type: "turn.failed", payload: [
            "error": AnyCodable("rate limit hit"),
        ])
        XCTAssertEqual(event.summary, "Turn failed: rate limit hit")
    }

    func testTurnFailed_withLongError_truncates() {
        let longError = String(repeating: "a", count: 100)
        let event = makeEvent(type: "turn.failed", payload: [
            "error": AnyCodable(longError),
        ])
        XCTAssertTrue(event.summary.hasPrefix("Turn failed: "))
        XCTAssertTrue(event.summary.count <= "Turn failed: ".count + 30)
    }

    func testTurnFailed_withoutError_showsFallback() {
        let event = makeEvent(type: "turn.failed")
        XCTAssertEqual(event.summary, "Turn failed")
    }

    // MARK: - Unknown Event Formatting

    func testUnknownEvent_formatsRawType_dotSeparated() {
        let event = makeEvent(type: "foo.bar")
        XCTAssertEqual(event.summary, "Foo Bar")
    }

    func testUnknownEvent_formatsRawType_underscoreSeparated() {
        let event = makeEvent(type: "some_unknown_type")
        XCTAssertEqual(event.summary, "Some Unknown Type")
    }

    func testUnknownEvent_formatsRawType_mixed() {
        let event = makeEvent(type: "foo.bar_baz")
        XCTAssertEqual(event.summary, "Foo Bar Baz")
    }

    // MARK: - Existing Event Summaries (Spot Checks)

    func testSessionStart_showsModel() {
        let event = makeEvent(type: "session.start", payload: [
            "model": AnyCodable("claude-sonnet-4-6-20260404"),
        ])
        XCTAssertTrue(event.summary.hasPrefix("Session started"))
    }

    func testSessionStart_unknownModel() {
        let event = makeEvent(type: "session.start")
        XCTAssertTrue(event.summary.contains("unknown"))
    }

    func testCapabilityInvocation_showsModelPrimitiveName() {
        let event = makeEvent(type: "capability.invocation.started", payload: [
            "modelPrimitiveName": AnyCodable("execute"),
            "arguments": AnyCodable(["file_path": "/foo/bar.swift"]),
        ])
        XCTAssertTrue(event.summary.contains("Execute"))
    }

    func testCapabilityInvocationResult_success_showsDuration() {
        let event = makeEvent(type: "capability.invocation.completed", payload: [
            "isError": AnyCodable(false),
            "duration": AnyCodable(522),
        ])
        XCTAssertEqual(event.summary, "522ms • success")
    }

    func testCapabilityInvocationResult_error_showsError() {
        let event = makeEvent(type: "capability.invocation.completed", payload: [
            "isError": AnyCodable(true),
        ])
        XCTAssertEqual(event.summary, "error")
    }

    func testMessageUser_showsContentPreview() {
        let event = makeEvent(type: "message.user", payload: [
            "content": AnyCodable("Hello world, this is a test message"),
        ])
        XCTAssertEqual(event.summary, "Hello world, this is a test message")
    }

    func testMessageUser_truncatesLongContent() {
        let longContent = String(repeating: "x", count: 100)
        let event = makeEvent(type: "message.user", payload: [
            "content": AnyCodable(longContent),
        ])
        XCTAssertTrue(event.summary.count <= 50)
    }

    func testSessionBranch_summary() {
        let event = makeEvent(type: "session.branch")
        XCTAssertEqual(event.summary, "Branch created")
    }

    func testContextCleared_summary() {
        let event = makeEvent(type: "context.cleared")
        XCTAssertEqual(event.summary, "Context cleared")
    }

    func testErrorAgent_showsCodeAndError() {
        let event = makeEvent(type: "error.agent", payload: [
            "code": AnyCodable("TIMEOUT"),
            "error": AnyCodable("Request timed out"),
        ])
        XCTAssertEqual(event.summary, "TIMEOUT: Request timed out")
    }

}
