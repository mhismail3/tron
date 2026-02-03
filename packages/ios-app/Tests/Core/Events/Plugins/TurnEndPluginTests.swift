import XCTest
@testable import TronMobile

final class TurnEndPluginTests: XCTestCase {

    // MARK: - Basic Parsing Tests

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

    // MARK: - TokenRecord Parsing Tests

    func testParseWithTokenRecord() throws {
        let json = """
        {
            "type": "agent.turn_end",
            "sessionId": "session-123",
            "data": {
                "turn": 1,
                "duration": 2500,
                "tokenRecord": {
                    "source": {
                        "provider": "anthropic",
                        "timestamp": "2024-01-15T10:30:00.000Z",
                        "rawInputTokens": 502,
                        "rawOutputTokens": 53,
                        "rawCacheReadTokens": 17332,
                        "rawCacheCreationTokens": 0
                    },
                    "computed": {
                        "contextWindowTokens": 17834,
                        "newInputTokens": 17834,
                        "previousContextBaseline": 0,
                        "calculationMethod": "anthropic_cache_aware"
                    },
                    "meta": {
                        "turn": 1,
                        "sessionId": "sess_abc123",
                        "extractedAt": "2024-01-15T10:30:00.000Z",
                        "normalizedAt": "2024-01-15T10:30:00.001Z"
                    }
                },
                "cost": 0.05,
                "contextLimit": 200000
            }
        }
        """.data(using: .utf8)!

        let event = try TurnEndPlugin.parse(from: json)

        XCTAssertNotNil(event.data?.tokenRecord)
        XCTAssertEqual(event.data?.tokenRecord?.source.provider, "anthropic")
        XCTAssertEqual(event.data?.tokenRecord?.source.rawInputTokens, 502)
        XCTAssertEqual(event.data?.tokenRecord?.source.rawOutputTokens, 53)
        XCTAssertEqual(event.data?.tokenRecord?.source.rawCacheReadTokens, 17332)
        XCTAssertEqual(event.data?.tokenRecord?.computed.contextWindowTokens, 17834)
        XCTAssertEqual(event.data?.tokenRecord?.computed.newInputTokens, 17834)
        XCTAssertEqual(event.data?.tokenRecord?.computed.calculationMethod, "anthropic_cache_aware")
        XCTAssertEqual(event.data?.tokenRecord?.meta.turn, 1)
    }

    func testParseOpenAITokenRecord() throws {
        let json = """
        {
            "type": "agent.turn_end",
            "data": {
                "turn": 2,
                "tokenRecord": {
                    "source": {
                        "provider": "openai",
                        "timestamp": "2024-01-15T10:30:00.000Z",
                        "rawInputTokens": 5000,
                        "rawOutputTokens": 200,
                        "rawCacheReadTokens": 0,
                        "rawCacheCreationTokens": 0
                    },
                    "computed": {
                        "contextWindowTokens": 5000,
                        "newInputTokens": 1000,
                        "previousContextBaseline": 4000,
                        "calculationMethod": "direct"
                    },
                    "meta": {
                        "turn": 2,
                        "sessionId": "sess_openai",
                        "extractedAt": "2024-01-15T10:30:00.000Z",
                        "normalizedAt": "2024-01-15T10:30:00.001Z"
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let event = try TurnEndPlugin.parse(from: json)

        XCTAssertNotNil(event.data?.tokenRecord)
        XCTAssertEqual(event.data?.tokenRecord?.source.provider, "openai")
        XCTAssertEqual(event.data?.tokenRecord?.computed.contextWindowTokens, 5000)
        XCTAssertEqual(event.data?.tokenRecord?.computed.newInputTokens, 1000)
        XCTAssertEqual(event.data?.tokenRecord?.computed.calculationMethod, "direct")
    }

    func testParseWithoutTokenRecord() throws {
        let json = """
        {
            "type": "agent.turn_end",
            "data": {
                "turn": 1,
                "duration": 1000
            }
        }
        """.data(using: .utf8)!

        let event = try TurnEndPlugin.parse(from: json)

        XCTAssertNil(event.data?.tokenRecord)
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

    func testTransformWithTokenRecord() throws {
        let json = """
        {
            "type": "agent.turn_end",
            "data": {
                "turn": 1,
                "duration": 2500,
                "tokenRecord": {
                    "source": {
                        "provider": "anthropic",
                        "timestamp": "2024-01-15T10:30:00.000Z",
                        "rawInputTokens": 500,
                        "rawOutputTokens": 100,
                        "rawCacheReadTokens": 8000,
                        "rawCacheCreationTokens": 0
                    },
                    "computed": {
                        "contextWindowTokens": 8500,
                        "newInputTokens": 8500,
                        "previousContextBaseline": 0,
                        "calculationMethod": "anthropic_cache_aware"
                    },
                    "meta": {
                        "turn": 1,
                        "sessionId": "sess_test",
                        "extractedAt": "2024-01-15T10:30:00.000Z",
                        "normalizedAt": "2024-01-15T10:30:00.001Z"
                    }
                },
                "cost": 0.03
            }
        }
        """.data(using: .utf8)!

        let event = try TurnEndPlugin.parse(from: json)
        let result = TurnEndPlugin.transform(event) as? TurnEndPlugin.Result

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.tokenRecord)
        XCTAssertEqual(result?.tokenRecord?.computed.contextWindowTokens, 8500)
        XCTAssertEqual(result?.tokenRecord?.computed.newInputTokens, 8500)
        XCTAssertEqual(result?.tokenRecord?.source.rawInputTokens, 500)
        XCTAssertEqual(result?.tokenRecord?.source.rawCacheReadTokens, 8000)
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
        XCTAssertNil(result?.tokenRecord)
    }
}
