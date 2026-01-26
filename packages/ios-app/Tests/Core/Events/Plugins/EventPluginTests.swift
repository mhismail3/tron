import XCTest
@testable import TronMobile

final class EventPluginTests: XCTestCase {

    override func setUp() {
        super.setUp()
        EventRegistry.shared.clearForTesting()
    }

    // MARK: - Protocol Conformance Tests

    func testAllPluginsConformToProtocol() {
        // Verify that all plugins have a non-empty event type
        EventRegistry.shared.registerAll()
        XCTAssertGreaterThan(EventRegistry.shared.pluginCount, 0)
    }

    func testEventTypesAreUnique() {
        EventRegistry.shared.registerAll()
        let types = EventRegistry.shared.registeredTypes
        let uniqueTypes = Set(types)
        XCTAssertEqual(types.count, uniqueTypes.count, "Event types must be unique")
    }

    func testAllPluginsHaveNonEmptyEventType() {
        // Test a sample of plugins
        XCTAssertFalse(TextDeltaPlugin.eventType.isEmpty)
        XCTAssertFalse(ThinkingDeltaPlugin.eventType.isEmpty)
        XCTAssertFalse(ToolStartPlugin.eventType.isEmpty)
        XCTAssertFalse(ToolEndPlugin.eventType.isEmpty)
        XCTAssertFalse(TurnStartPlugin.eventType.isEmpty)
        XCTAssertFalse(TurnEndPlugin.eventType.isEmpty)
        XCTAssertFalse(CompletePlugin.eventType.isEmpty)
        XCTAssertFalse(ErrorPlugin.eventType.isEmpty)
    }

    // MARK: - Registry Tests

    func testRegisterPlugin() {
        EventRegistry.shared.register(TextDeltaPlugin.self)
        XCTAssertTrue(EventRegistry.shared.hasPlugin(for: "agent.text_delta"))
        XCTAssertEqual(EventRegistry.shared.pluginCount, 1)
    }

    func testParseKnownEventType() {
        EventRegistry.shared.register(TextDeltaPlugin.self)

        let json = """
        {
            "type": "agent.text_delta",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "delta": "Hello, world!"
            }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "agent.text_delta", data: json)
        XCTAssertNotNil(result)

        if case .plugin(let type, _, let sessionId, let transform) = result {
            XCTAssertEqual(type, "agent.text_delta")
            XCTAssertEqual(sessionId, "session-123")

            let eventResult = transform()
            XCTAssertNotNil(eventResult)
            if let textResult = eventResult as? TextDeltaPlugin.Result {
                XCTAssertEqual(textResult.delta, "Hello, world!")
            } else {
                XCTFail("Expected TextDeltaPlugin.Result")
            }
        } else {
            XCTFail("Expected .plugin case")
        }
    }

    func testParseUnknownEventType() {
        EventRegistry.shared.registerAll()

        let json = """
        {"type": "some.unknown.event"}
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "some.unknown.event", data: json)

        if case .unknown(let type) = result {
            XCTAssertEqual(type, "some.unknown.event")
        } else {
            XCTFail("Expected .unknown case")
        }
    }

    func testSessionIdExtraction() {
        EventRegistry.shared.register(TextDeltaPlugin.self)

        let json = """
        {
            "type": "agent.text_delta",
            "sessionId": "session-456",
            "data": { "delta": "test" }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "agent.text_delta", data: json)
        XCTAssertEqual(result?.sessionId, "session-456")
    }

    func testSessionIdNilWhenMissing() {
        EventRegistry.shared.register(ConnectedPlugin.self)

        let json = """
        {
            "type": "connection.established",
            "data": { "serverId": "server-1" }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "connection.established", data: json)
        XCTAssertNil(result?.sessionId)
    }

    func testMatchesSession() {
        EventRegistry.shared.register(TextDeltaPlugin.self)

        let json = """
        {
            "type": "agent.text_delta",
            "sessionId": "session-789",
            "data": { "delta": "test" }
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "agent.text_delta", data: json)!

        XCTAssertTrue(result.matchesSession("session-789"))
        XCTAssertFalse(result.matchesSession("other-session"))
        XCTAssertFalse(result.matchesSession(nil))
    }

    func testMatchesSessionGlobalEvent() {
        EventRegistry.shared.register(ConnectedPlugin.self)

        let json = """
        {
            "type": "connection.established",
            "data": {}
        }
        """.data(using: .utf8)!

        let result = EventRegistry.shared.parse(type: "connection.established", data: json)!

        // Global events (no sessionId) match any session
        XCTAssertTrue(result.matchesSession("any-session"))
        XCTAssertTrue(result.matchesSession(nil))
    }

    func testRegisteredPluginCount() {
        EventRegistry.shared.registerAll()
        // Should have all 27+ plugins registered
        XCTAssertGreaterThanOrEqual(EventRegistry.shared.pluginCount, 27)
    }
}
