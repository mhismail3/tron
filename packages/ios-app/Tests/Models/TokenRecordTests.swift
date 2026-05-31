import XCTest
@testable import TronMobile

final class TokenRecordTests: XCTestCase {
    func testDecodesCompleteAnthropicTokenRecord() throws {
        let record = try decodeRecord(
            provider: "anthropic",
            input: 502,
            output: 53,
            cacheRead: 17_332,
            cachedInput: 17_332,
            cacheCreation: 0,
            cache5m: 0,
            cache1h: 0,
            reasoning: 0,
            total: 17_887,
            context: 17_834,
            newInput: 502,
            method: "anthropic_cache_aware",
            pricing: Self.pricing(cost: Self.cost(total: 0.012))
        )

        XCTAssertEqual(record.source.provider, "anthropic")
        XCTAssertEqual(record.source.rawInputTokens, 502)
        XCTAssertEqual(record.source.rawOutputTokens, 53)
        XCTAssertEqual(record.source.rawCacheReadTokens, 17_332)
        XCTAssertEqual(record.source.rawCachedInputTokens, 17_332)
        XCTAssertEqual(record.source.rawTotalTokens, 17_887)
        XCTAssertEqual(record.computed.contextWindowTokens, 17_834)
        XCTAssertEqual(record.computed.newInputTokens, 502)
        XCTAssertEqual(record.meta.model, "claude-sonnet-4-5")
        XCTAssertEqual(record.meta.contextSegmentId, "sess_abc123:anthropic:claude-sonnet-4-5")
        XCTAssertTrue(record.pricing.available)
        XCTAssertEqual(record.pricing.cost?.totalCost, 0.012)
    }

    func testDecodesOpenAIReasoningAndCachedTokens() throws {
        let record = try decodeRecord(
            provider: "openai",
            input: 5_000,
            output: 200,
            cacheRead: 3_000,
            cachedInput: 3_000,
            cacheCreation: 0,
            cache5m: 0,
            cache1h: 0,
            reasoning: 75,
            total: 5_200,
            context: 5_000,
            newInput: 1_000,
            previous: 4_000,
            method: "direct",
            pricing: Self.pricing(cost: Self.cost(baseInputTokens: 2_000, total: 0.02))
        )

        XCTAssertEqual(record.source.provider, "openai")
        XCTAssertEqual(record.source.rawReasoningOutputTokens, 75)
        XCTAssertEqual(record.source.rawCachedInputTokens, 3_000)
        XCTAssertEqual(record.computed.contextWindowTokens, 5_000)
        XCTAssertEqual(record.computed.newInputTokens, 1_000)
    }

    func testDecodesGoogleThoughtAndToolUseTokens() throws {
        let record = try decodeRecord(
            provider: "google",
            input: 8_000,
            output: 300,
            cacheRead: 1_500,
            cachedInput: 1_500,
            cacheCreation: 0,
            cache5m: 0,
            cache1h: 0,
            thought: 120,
            toolUse: 64,
            total: 8_420,
            context: 8_000,
            newInput: 8_000,
            method: "direct",
            pricing: Self.pricing(cost: Self.cost(baseInputTokens: 6_500, total: 0.018))
        )

        XCTAssertEqual(record.source.provider, "google")
        XCTAssertEqual(record.source.rawThoughtTokens, 120)
        XCTAssertEqual(record.source.rawToolUsePromptTokens, 64)
        XCTAssertEqual(record.source.rawTotalTokens, 8_420)
    }

    func testDecodesAnthropicPerTTLCacheWrites() throws {
        let record = try decodeRecord(
            provider: "anthropic",
            input: 500,
            output: 100,
            cacheRead: 0,
            cachedInput: 0,
            cacheCreation: 8_000,
            cache5m: 3_000,
            cache1h: 5_000,
            total: 8_600,
            context: 8_500,
            newInput: 8_500,
            method: "anthropic_cache_aware",
            pricing: Self.pricing(cost: Self.cost(cacheWriteTokens: 8_000, cache5m: 3_000, cache1h: 5_000, total: 0.03))
        )

        XCTAssertEqual(record.source.rawCacheCreationTokens, 8_000)
        XCTAssertEqual(record.source.rawCacheCreation5mTokens, 3_000)
        XCTAssertEqual(record.source.rawCacheCreation1hTokens, 5_000)
        XCTAssertEqual(record.computed.contextWindowTokens, 8_500)
        XCTAssertEqual(record.formattedCacheWrite, 8_000.formattedTokenCount)
    }

    func testUnavailablePricingDecodesWithoutLocalCostGuess() throws {
        let record = try decodeRecord(
            provider: "ollama",
            input: 10,
            output: 5,
            cacheRead: 0,
            cachedInput: 0,
            cacheCreation: 0,
            cache5m: 0,
            cache1h: 0,
            total: 15,
            context: 10,
            newInput: 10,
            method: "direct",
            pricing: Self.pricing(available: false, reason: "unsupported_model_pricing", cost: nil)
        )

        XCTAssertFalse(record.pricing.available)
        XCTAssertEqual(record.pricing.reason, "unsupported_model_pricing")
        XCTAssertNil(record.pricing.cost)
    }

    func testTokenSourceTotalTokensUsesProviderTotal() throws {
        let source = try JSONDecoder().decode(TokenSource.self, from: sourceJSON(total: 999))
        XCTAssertEqual(source.totalTokens, 999)
    }

    func testMissingRequiredTokenRecordFieldsFail() throws {
        let data = """
        {
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
                "newInputTokens": 502,
                "previousContextBaseline": 0,
                "calculationMethod": "anthropic_cache_aware"
            },
            "meta": {
                "turn": 1,
                "sessionId": "sess_abc123",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            }
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(TokenRecord.self, from: data))
    }

    func testDictionaryFactoryFailsForPartialOrWrongTypedRecords() {
        var dict = fullRecordDict()
        dict["source"] = ["provider": "openai"] as [String: Any]
        XCTAssertNil(TokenRecord.from(dict: dict))

        dict = fullRecordDict()
        dict["meta"] = ["sessionId": "sess_partial"] as [String: Any]
        XCTAssertNil(TokenRecord.from(dict: dict))

        dict = fullRecordDict()
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

    private func decodeRecord(
        provider: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cachedInput: Int,
        cacheCreation: Int,
        cache5m: Int,
        cache1h: Int,
        reasoning: Int = 0,
        thought: Int = 0,
        toolUse: Int = 0,
        total: Int,
        context: Int,
        newInput: Int,
        previous: Int = 0,
        method: String,
        pricing: [String: Any]
    ) throws -> TokenRecord {
        let data = try JSONSerialization.data(withJSONObject: fullRecordDict(
            provider: provider,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cachedInput: cachedInput,
            cacheCreation: cacheCreation,
            cache5m: cache5m,
            cache1h: cache1h,
            reasoning: reasoning,
            thought: thought,
            toolUse: toolUse,
            total: total,
            context: context,
            newInput: newInput,
            previous: previous,
            method: method,
            pricing: pricing
        ))
        return try JSONDecoder().decode(TokenRecord.self, from: data)
    }

    private func fullRecordDict(
        provider: String = "anthropic",
        input: Int = 502,
        output: Int = 53,
        cacheRead: Int = 17_332,
        cachedInput: Int = 17_332,
        cacheCreation: Int = 0,
        cache5m: Int = 0,
        cache1h: Int = 0,
        reasoning: Int = 0,
        thought: Int = 0,
        toolUse: Int = 0,
        total: Int = 17_887,
        context: Int = 17_834,
        newInput: Int = 502,
        previous: Int = 0,
        method: String = "anthropic_cache_aware",
        pricing: [String: Any] = TokenRecordTests.pricing(cost: TokenRecordTests.cost(total: 0.012))
    ) -> [String: Any] {
        [
            "source": [
                "provider": provider,
                "timestamp": "2024-01-15T10:30:00.000Z",
                "rawInputTokens": input,
                "rawOutputTokens": output,
                "rawCacheReadTokens": cacheRead,
                "rawCachedInputTokens": cachedInput,
                "rawCacheCreationTokens": cacheCreation,
                "rawCacheCreation5mTokens": cache5m,
                "rawCacheCreation1hTokens": cache1h,
                "rawReasoningOutputTokens": reasoning,
                "rawThoughtTokens": thought,
                "rawToolUsePromptTokens": toolUse,
                "rawTotalTokens": total
            ] as [String: Any],
            "computed": [
                "contextWindowTokens": context,
                "newInputTokens": newInput,
                "previousContextBaseline": previous,
                "calculationMethod": method
            ] as [String: Any],
            "meta": [
                "turn": 1,
                "sessionId": "sess_abc123",
                "model": "claude-sonnet-4-5",
                "contextSegmentId": "sess_abc123:\(provider):claude-sonnet-4-5",
                "baselineResetReason": previous == 0 ? "initial_or_reset" : "none",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            ] as [String: Any],
            "pricing": pricing
        ]
    }

    private static func pricing(
        available: Bool = true,
        reason: String? = nil,
        cost: [String: Any]?
    ) -> [String: Any] {
        [
            "available": available,
            "model": "claude-sonnet-4-5",
            "reason": reason ?? NSNull(),
            "cost": cost ?? NSNull()
        ]
    }

    private static func cost(
        baseInputTokens: Int = 502,
        outputTokens: Int = 53,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        cache5m: Int = 0,
        cache1h: Int = 0,
        total: Double
    ) -> [String: Any] {
        [
            "baseInputTokens": baseInputTokens,
            "outputTokens": outputTokens,
            "cacheReadTokens": cacheReadTokens,
            "cacheWriteTokens": cacheWriteTokens,
            "cacheWrite5mTokens": cache5m,
            "cacheWrite1hTokens": cache1h,
            "baseInputCost": 0.001,
            "outputCost": 0.002,
            "cacheReadCost": 0.003,
            "cacheWriteCost": 0.004,
            "totalCost": total,
            "currency": "USD"
        ]
    }

    private func sourceJSON(total: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "provider": "anthropic",
            "timestamp": "2024-01-15T10:30:00.000Z",
            "rawInputTokens": 500,
            "rawOutputTokens": 100,
            "rawCacheReadTokens": 0,
            "rawCachedInputTokens": 0,
            "rawCacheCreationTokens": 0,
            "rawCacheCreation5mTokens": 0,
            "rawCacheCreation1hTokens": 0,
            "rawReasoningOutputTokens": 0,
            "rawThoughtTokens": 0,
            "rawToolUsePromptTokens": 0,
            "rawTotalTokens": total
        ] as [String: Any])
    }
}
