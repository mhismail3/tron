import XCTest
@testable import TronMobile

final class TurnEndPluginTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseValidEvent() throws {
        let json = """
        {
            "type": "agent.turn_end",
            "sessionId": "session-123",
            "timestamp": "2025-01-26T10:00:00Z",
            "data": {
                "turn": 3,
                "duration": 5000,
                "stopReason": "end_turn",
                "cost": 0.025,
                "contextLimit": 200000
            }
        }
        """.data(using: .utf8)!

        let event = try TurnEndPlugin.parse(from: json)

        XCTAssertEqual(event.type, "agent.turn_end")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data?.turn, 3)
        XCTAssertEqual(event.data?.duration, 5000)
        XCTAssertEqual(event.data?.stopReason, "end_turn")
        XCTAssertEqual(event.data?.cost, 0.025)
        XCTAssertEqual(event.data?.contextLimit, 200000)
    }

    func testParseWithCostAsString() throws {
        let json = """
        {
            "type": "agent.turn_end",
            "sessionId": "session-123",
            "data": {
                "turn": 1,
                "cost": "0.0125"
            }
        }
        """.data(using: .utf8)!

        let event = try TurnEndPlugin.parse(from: json)

        XCTAssertEqual(event.data?.cost, 0.0125)
    }

    func testParseWithBothTurnAndTurnNumber() throws {
        let json = """
        {
            "type": "agent.turn_end",
            "data": {
                "turn": 5,
                "turnNumber": 10
            }
        }
        """.data(using: .utf8)!

        let event = try TurnEndPlugin.parse(from: json)

        // Should prefer turn over turnNumber
        XCTAssertEqual(event.data?.number, 5)
    }

    func testParseWithTurnNumberOnly() throws {
        let json = """
        {
            "type": "agent.turn_end",
            "data": {
                "turnNumber": 7
            }
        }
        """.data(using: .utf8)!

        let event = try TurnEndPlugin.parse(from: json)
        XCTAssertEqual(event.data?.number, 7)
    }

    func testParseWithoutData() throws {
        let json = """
        {
            "type": "agent.turn_end",
            "sessionId": "session-123"
        }
        """.data(using: .utf8)!

        let event = try TurnEndPlugin.parse(from: json)

        XCTAssertNil(event.data)
    }

    // MARK: - Transform Tests

    func testTransform() throws {
        let json = """
        {
            "type": "agent.turn_end",
            "sessionId": "session-456",
            "data": {
                "turn": 2,
                "duration": 3000,
                "stopReason": "tool_use",
                "cost": 0.05,
                "contextLimit": 128000
            }
        }
        """.data(using: .utf8)!

        let event = try TurnEndPlugin.parse(from: json)
        let result = TurnEndPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let turnResult = result as? TurnEndPlugin.Result else {
            XCTFail("Expected TurnEndPlugin.Result")
            return
        }

        XCTAssertEqual(turnResult.turnNumber, 2)
        XCTAssertEqual(turnResult.duration, 3000)
        XCTAssertEqual(turnResult.stopReason, "tool_use")
        XCTAssertEqual(turnResult.cost, 0.05)
        XCTAssertEqual(turnResult.contextLimit, 128000)
    }

    func testTransformWithNilData() throws {
        let json = """
        {
            "type": "agent.turn_end",
            "sessionId": "session-789"
        }
        """.data(using: .utf8)!

        let event = try TurnEndPlugin.parse(from: json)
        let result = TurnEndPlugin.transform(event) as? TurnEndPlugin.Result

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.turnNumber, 1)  // Default to 1
        XCTAssertNil(result?.duration)
        XCTAssertNil(result?.stopReason)
        XCTAssertNil(result?.cost)
    }

    // MARK: - Parity Tests

    func testParityWithLegacyTurnEndEvent() throws {
        let json = """
        {
            "type": "agent.turn_end",
            "sessionId": "parity-session",
            "data": {
                "turn": 4,
                "duration": 2500,
                "stopReason": "end_turn",
                "cost": 0.015,
                "contextLimit": 100000
            }
        }
        """.data(using: .utf8)!

        // Parse with plugin system
        let pluginEvent = try TurnEndPlugin.parse(from: json)

        // Parse with legacy system
        let legacyEvent = try JSONDecoder().decode(TurnEndEvent.self, from: json)

        // Verify parity
        XCTAssertEqual(TurnEndPlugin.sessionId(from: pluginEvent), legacyEvent.sessionId)
        XCTAssertEqual(pluginEvent.data?.number, legacyEvent.turnNumber)
        XCTAssertEqual(pluginEvent.data?.duration, legacyEvent.data?.duration)
        XCTAssertEqual(pluginEvent.data?.stopReason, legacyEvent.stopReason)
        XCTAssertEqual(pluginEvent.data?.cost, legacyEvent.cost)
        XCTAssertEqual(pluginEvent.data?.contextLimit, legacyEvent.contextLimit)
    }
}
