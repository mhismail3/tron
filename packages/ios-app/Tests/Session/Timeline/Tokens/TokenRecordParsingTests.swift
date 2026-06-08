import XCTest
@testable import TronMobile

final class TokenRecordParsingTests: XCTestCase {
    func testParseValidTokenRecord() {
        let record = TokenRecord.from(dict: makeFullTokenRecordDict())

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.source.provider, "anthropic")
        XCTAssertEqual(record?.source.rawInputTokens, 502)
        XCTAssertEqual(record?.source.rawCachedInputTokens, 17_332)
        XCTAssertEqual(record?.source.rawCacheCreation5mTokens, 0)
        XCTAssertEqual(record?.source.rawReasoningOutputTokens, 0)
        XCTAssertEqual(record?.source.rawTotalTokens, 17_887)
        XCTAssertEqual(record?.computed.contextWindowTokens, 17_834)
        XCTAssertEqual(record?.meta.turn, 1)
        XCTAssertEqual(record?.meta.model, "claude-sonnet-4-5")
        XCTAssertEqual(record?.meta.contextSegmentId, "sess_abc123:anthropic:claude-sonnet-4-5")
        XCTAssertTrue(record?.pricing.available == true)
        XCTAssertEqual(record?.pricing.cost?.totalCost, 0.012)
    }

    func testMissingRequiredSectionsFail() {
        for key in ["source", "computed", "meta", "pricing"] {
            var dict = makeFullTokenRecordDict()
            dict.removeValue(forKey: key)
            XCTAssertNil(TokenRecord.from(dict: dict), "missing \(key) should fail")
        }
    }

    func testNilEmptyAndMalformedInputsFail() {
        XCTAssertNil(TokenRecord.from(dict: nil))
        XCTAssertNil(TokenRecord.from(dict: [:]))

        var dict = makeFullTokenRecordDict()
        dict["source"] = "not a dict"
        XCTAssertNil(TokenRecord.from(dict: dict))

        dict = makeFullTokenRecordDict()
        dict["computed"] = 42
        XCTAssertNil(TokenRecord.from(dict: dict))
    }

    func testPartialAndWrongTypedDataFailsInsteadOfDefaulting() {
        var dict = makeFullTokenRecordDict()
        dict["source"] = ["provider": "openai"] as [String: Any]
        XCTAssertNil(TokenRecord.from(dict: dict))

        dict = makeFullTokenRecordDict()
        dict["meta"] = ["sessionId": "sess_partial"] as [String: Any]
        XCTAssertNil(TokenRecord.from(dict: dict))

        dict = makeFullTokenRecordDict()
        dict["computed"] = ["contextWindowTokens": 5_000] as [String: Any]
        XCTAssertNil(TokenRecord.from(dict: dict))

        dict = makeFullTokenRecordDict()
        dict["source"] = [
            "provider": "anthropic",
            "timestamp": "2024-01-15T10:30:00.000Z",
            "rawInputTokens": "not_a_number",
            "rawOutputTokens": "also_not",
            "rawCacheReadTokens": true,
            "rawCachedInputTokens": 0,
            "rawCacheCreationTokens": 0,
            "rawCacheCreation5mTokens": 0,
            "rawCacheCreation1hTokens": 0,
            "rawReasoningOutputTokens": 0,
            "rawThoughtTokens": 0,
            "rawToolUsePromptTokens": 0,
            "rawTotalTokens": 0
        ] as [String: Any]
        XCTAssertNil(TokenRecord.from(dict: dict))
    }

    func testExtraKeysAreIgnored() {
        var dict = makeFullTokenRecordDict()
        dict["extraField"] = "ignored"
        if var source = dict["source"] as? [String: Any] {
            source["unknownField"] = 999
            dict["source"] = source
        }

        let record = TokenRecord.from(dict: dict)

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.source.provider, "anthropic")
    }

    private func makeFullTokenRecordDict() -> [String: Any] {
        [
            "source": [
                "provider": "anthropic",
                "timestamp": "2024-01-15T10:30:00.000Z",
                "rawInputTokens": 502,
                "rawOutputTokens": 53,
                "rawCacheReadTokens": 17_332,
                "rawCachedInputTokens": 17_332,
                "rawCacheCreationTokens": 0,
                "rawCacheCreation5mTokens": 0,
                "rawCacheCreation1hTokens": 0,
                "rawReasoningOutputTokens": 0,
                "rawThoughtTokens": 0,
                "rawToolUsePromptTokens": 0,
                "rawTotalTokens": 17_887
            ] as [String: Any],
            "computed": [
                "contextWindowTokens": 17_834,
                "newInputTokens": 502,
                "previousContextBaseline": 0,
                "calculationMethod": "anthropic_cache_aware"
            ] as [String: Any],
            "meta": [
                "turn": 1,
                "sessionId": "sess_abc123",
                "model": "claude-sonnet-4-5",
                "contextSegmentId": "sess_abc123:anthropic:claude-sonnet-4-5",
                "baselineResetReason": "initial_or_reset",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            ] as [String: Any],
            "pricing": [
                "available": true,
                "model": "claude-sonnet-4-5",
                "reason": NSNull(),
                "cost": [
                    "baseInputTokens": 502,
                    "outputTokens": 53,
                    "cacheReadTokens": 17_332,
                    "cacheWriteTokens": 0,
                    "cacheWrite5mTokens": 0,
                    "cacheWrite1hTokens": 0,
                    "baseInputCost": 0.001,
                    "outputCost": 0.002,
                    "cacheReadCost": 0.009,
                    "cacheWriteCost": 0,
                    "totalCost": 0.012,
                    "currency": "USD"
                ] as [String: Any]
            ] as [String: Any]
        ]
    }
}
