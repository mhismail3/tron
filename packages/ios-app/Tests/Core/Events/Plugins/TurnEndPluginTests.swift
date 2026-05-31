import XCTest
@testable import TronMobile

final class TurnEndPluginTests: XCTestCase {
    func testParseValidEvent() throws {
        let event = try TurnEndPlugin.parse(from: jsonData("""
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
        """))

        XCTAssertEqual(event.type, "agent.turn_end")
        XCTAssertEqual(event.sessionId, "session-123")
        XCTAssertEqual(event.data?.turn, 3)
        XCTAssertEqual(event.data?.duration, 5000)
        XCTAssertEqual(event.data?.stopReason, "end_turn")
        XCTAssertEqual(event.data?.cost, 0.025)
        XCTAssertEqual(event.data?.contextLimit, 200000)
    }

    func testParseWithCostAsString() throws {
        let event = try TurnEndPlugin.parse(from: jsonData("""
        {
            "type": "agent.turn_end",
            "sessionId": "session-123",
            "data": {
                "turn": 1,
                "cost": "0.0125"
            }
        }
        """))

        XCTAssertEqual(event.data?.cost, 0.0125)
    }

    func testTurnNumberAliasesRequireAtLeastOneExplicitTurnField() throws {
        let both = try TurnEndPlugin.parse(from: jsonData("""
        {"type": "agent.turn_end", "data": {"turn": 5, "turnNumber": 10}}
        """))
        XCTAssertEqual(both.data?.number, 5)

        let aliasOnly = try TurnEndPlugin.parse(from: jsonData("""
        {"type": "agent.turn_end", "data": {"turnNumber": 7}}
        """))
        XCTAssertEqual(aliasOnly.data?.number, 7)

        let missing = try TurnEndPlugin.parse(from: jsonData("""
        {"type": "agent.turn_end", "sessionId": "session-789"}
        """))
        XCTAssertNil(TurnEndPlugin.transform(missing))
    }

    func testParseWithTokenRecord() throws {
        let event = try TurnEndPlugin.parse(from: jsonData("""
        {
            "type": "agent.turn_end",
            "sessionId": "session-123",
            "data": {
                "turn": 1,
                "duration": 2500,
                "tokenRecord": \(tokenRecordJSON(provider: "anthropic", cacheRead: 17332, context: 17834, newInput: 502))
            }
        }
        """))

        XCTAssertNotNil(event.data?.tokenRecord)
        XCTAssertEqual(event.data?.tokenRecord?.source.provider, "anthropic")
        XCTAssertEqual(event.data?.tokenRecord?.source.rawInputTokens, 502)
        XCTAssertEqual(event.data?.tokenRecord?.source.rawOutputTokens, 53)
        XCTAssertEqual(event.data?.tokenRecord?.source.rawCacheReadTokens, 17_332)
        XCTAssertEqual(event.data?.tokenRecord?.source.rawCachedInputTokens, 17_332)
        XCTAssertEqual(event.data?.tokenRecord?.computed.contextWindowTokens, 17_834)
        XCTAssertEqual(event.data?.tokenRecord?.computed.newInputTokens, 502)
        XCTAssertEqual(event.data?.tokenRecord?.meta.model, "claude-sonnet-4-5")
    }

    func testMalformedTokenRecordFailsDecode() throws {
        XCTAssertThrowsError(try TurnEndPlugin.parse(from: jsonData("""
        {
            "type": "agent.turn_end",
            "data": {
                "turn": 1,
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
        """)))
    }

    func testTransform() throws {
        let event = try TurnEndPlugin.parse(from: jsonData("""
        {
            "type": "agent.turn_end",
            "sessionId": "session-456",
            "data": {
                "turn": 2,
                "duration": 3000,
                "stopReason": "capability_invocation",
                "cost": 0.05,
                "contextLimit": 128000
            }
        }
        """))
        let result = TurnEndPlugin.transform(event)

        XCTAssertNotNil(result)
        guard let turnResult = result as? TurnEndPlugin.Result else {
            XCTFail("Expected TurnEndPlugin.Result")
            return
        }
        XCTAssertEqual(turnResult.turnNumber, 2)
        XCTAssertEqual(turnResult.duration, 3000)
        XCTAssertEqual(turnResult.stopReason, "capability_invocation")
        XCTAssertEqual(turnResult.cost, 0.05)
        XCTAssertEqual(turnResult.contextLimit, 128000)
    }

    func testTransformWithTokenRecord() throws {
        let event = try TurnEndPlugin.parse(from: jsonData("""
        {
            "type": "agent.turn_end",
            "data": {
                "turn": 1,
                "duration": 2500,
                "tokenRecord": \(tokenRecordJSON(provider: "openai", cacheRead: 3000, context: 5000, newInput: 1000, method: "direct"))
            }
        }
        """))
        let result = TurnEndPlugin.transform(event) as? TurnEndPlugin.Result

        XCTAssertNotNil(result?.tokenRecord)
        XCTAssertEqual(result?.tokenRecord?.computed.contextWindowTokens, 5_000)
        XCTAssertEqual(result?.tokenRecord?.computed.newInputTokens, 1_000)
        XCTAssertEqual(result?.tokenRecord?.source.rawCachedInputTokens, 3_000)
    }

    private func tokenRecordJSON(
        provider: String,
        cacheRead: Int,
        context: Int,
        newInput: Int,
        method: String = "anthropic_cache_aware"
    ) -> String {
        """
        {
            "source": {
                "provider": "\(provider)",
                "timestamp": "2024-01-15T10:30:00.000Z",
                "rawInputTokens": 502,
                "rawOutputTokens": 53,
                "rawCacheReadTokens": \(cacheRead),
                "rawCachedInputTokens": \(cacheRead),
                "rawCacheCreationTokens": 0,
                "rawCacheCreation5mTokens": 0,
                "rawCacheCreation1hTokens": 0,
                "rawReasoningOutputTokens": 0,
                "rawThoughtTokens": 0,
                "rawToolUsePromptTokens": 0,
                "rawTotalTokens": \(502 + 53 + cacheRead)
            },
            "computed": {
                "contextWindowTokens": \(context),
                "newInputTokens": \(newInput),
                "previousContextBaseline": 0,
                "calculationMethod": "\(method)"
            },
            "meta": {
                "turn": 1,
                "sessionId": "sess_abc123",
                "model": "claude-sonnet-4-5",
                "contextSegmentId": "sess_abc123:\(provider):claude-sonnet-4-5",
                "baselineResetReason": "initial_or_reset",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            },
            "pricing": {
                "available": true,
                "model": "claude-sonnet-4-5",
                "cost": {
                    "baseInputTokens": 502,
                    "outputTokens": 53,
                    "cacheReadTokens": \(cacheRead),
                    "cacheWriteTokens": 0,
                    "cacheWrite5mTokens": 0,
                    "cacheWrite1hTokens": 0,
                    "baseInputCost": 0.001,
                    "outputCost": 0.002,
                    "cacheReadCost": 0.003,
                    "cacheWriteCost": 0,
                    "totalCost": 0.006,
                    "currency": "USD"
                }
            }
        }
        """
    }

    private func jsonData(_ json: String) -> Data {
        json.data(using: .utf8)!
    }
}
