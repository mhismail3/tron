import XCTest
@testable import TronMobile

final class ServerRestartingPluginTests: XCTestCase {

    override func setUp() {
        super.setUp()
        EventRegistry.shared.clearForTesting()
    }

    // MARK: - Event Type

    func testEventType() {
        XCTAssertEqual(ServerRestartingPlugin.eventType, "server.restarting")
    }

    // MARK: - Parsing

    func testParseFullEvent() {
        EventRegistry.shared.register(ServerRestartingPlugin.self)

        let json = """
        {
            "type": "server.restarting",
            "timestamp": "2026-02-23T01:00:00Z",
            "data": {
                "reason": "deploy",
                "commit": "abc123",
                "restartExpectedMs": 5000
            }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "server.restarting", data: json)
        XCTAssertNotNil(result)

        if case .plugin(let type, _, let sessionId, let transform) = result {
            XCTAssertEqual(type, "server.restarting")
            XCTAssertNil(sessionId, "server.restarting is a global event with no sessionId")

            let eventResult = transform() as? ServerRestartingPlugin.Result
            XCTAssertNotNil(eventResult)
            XCTAssertEqual(eventResult?.reason, "deploy")
            XCTAssertEqual(eventResult?.commit, "abc123")
            XCTAssertEqual(eventResult?.restartExpectedMs, 5000)
        } else {
            XCTFail("Expected .plugin case")
        }
    }

    func testParseMinimalEvent_defaultValues() {
        EventRegistry.shared.register(ServerRestartingPlugin.self)

        let json = """
        {
            "type": "server.restarting"
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "server.restarting", data: json)
        XCTAssertNotNil(result)

        if case .plugin(_, _, _, let transform) = result {
            let eventResult = transform() as? ServerRestartingPlugin.Result
            XCTAssertNotNil(eventResult)
            XCTAssertEqual(eventResult?.reason, "deploy")
            XCTAssertEqual(eventResult?.commit, "unknown")
            XCTAssertEqual(eventResult?.restartExpectedMs, 5000)
        } else {
            XCTFail("Expected .plugin case")
        }
    }

    func testParsePartialData() {
        EventRegistry.shared.register(ServerRestartingPlugin.self)

        let json = """
        {
            "type": "server.restarting",
            "data": {
                "reason": "manual",
                "restartExpectedMs": 3000
            }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "server.restarting", data: json)

        if case .plugin(_, _, _, let transform) = result {
            let eventResult = transform() as? ServerRestartingPlugin.Result
            XCTAssertEqual(eventResult?.reason, "manual")
            XCTAssertEqual(eventResult?.commit, "unknown")
            XCTAssertEqual(eventResult?.restartExpectedMs, 3000)
        } else {
            XCTFail("Expected .plugin case")
        }
    }

    // MARK: - Global Event (no session scoping)

    func testIsGlobalEvent_matchesAnySession() {
        EventRegistry.shared.register(ServerRestartingPlugin.self)

        let json = """
        {
            "type": "server.restarting",
            "data": {"reason": "deploy", "commit": "abc", "restartExpectedMs": 5000}
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "server.restarting", data: json)!

        // Global events match any session
        XCTAssertTrue(result.matchesSession("session-1"))
        XCTAssertTrue(result.matchesSession("session-2"))
        XCTAssertTrue(result.matchesSession(nil))
    }

    func testSessionIdAlwaysNil() {
        XCTAssertNil(ServerRestartingPlugin.sessionId(from: ServerRestartingPlugin.EventData(
            type: "server.restarting",
            timestamp: nil,
            data: nil
        )))
    }

    // MARK: - Dispatch

    @MainActor
    func testDispatchCallsHandler() {
        let mock = MockEventDispatchContext()
        let result = ServerRestartingPlugin.Result(
            reason: "deploy",
            commit: "def456",
            restartExpectedMs: 7000
        )

        ServerRestartingPlugin.dispatch(result: result, context: mock)

        XCTAssertNotNil(mock.handleServerRestartingCalledWith)
        XCTAssertEqual(mock.handleServerRestartingCalledWith?.reason, "deploy")
        XCTAssertEqual(mock.handleServerRestartingCalledWith?.commit, "def456")
        XCTAssertEqual(mock.handleServerRestartingCalledWith?.restartExpectedMs, 7000)
    }

    @MainActor
    func testDispatchIgnoresWrongResultType() {
        let mock = MockEventDispatchContext()

        // Pass a wrong result type — should be silently ignored
        let wrongResult = TextDeltaPlugin.Result(delta: "hello", messageIndex: nil)
        ServerRestartingPlugin.dispatch(result: wrongResult, context: mock)

        XCTAssertNil(mock.handleServerRestartingCalledWith)
    }
}
