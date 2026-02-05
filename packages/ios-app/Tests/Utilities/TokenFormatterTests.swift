import XCTest
@testable import TronMobile

final class TokenFormatterTests: XCTestCase {

    // MARK: - format() Compact Style Tests (default)

    func test_format_compact_returnsRawNumber_under1000() {
        XCTAssertEqual(TokenFormatter.format(0), "0")
        XCTAssertEqual(TokenFormatter.format(1), "1")
        XCTAssertEqual(TokenFormatter.format(500), "500")
        XCTAssertEqual(TokenFormatter.format(999), "999")
    }

    func test_format_compact_returns1kFormat_at1000() {
        XCTAssertEqual(TokenFormatter.format(1000), "1.0k")
    }

    func test_format_compact_returns1_5kFormat_at1500() {
        XCTAssertEqual(TokenFormatter.format(1500), "1.5k")
    }

    func test_format_compact_handlesLargeNumbers() {
        XCTAssertEqual(TokenFormatter.format(10000), "10.0k")
        XCTAssertEqual(TokenFormatter.format(100000), "100.0k")
        XCTAssertEqual(TokenFormatter.format(12345), "12.3k")
    }

    func test_format_compact_handlesMillions() {
        XCTAssertEqual(TokenFormatter.format(1_000_000), "1.0M")
        XCTAssertEqual(TokenFormatter.format(1_500_000), "1.5M")
        XCTAssertEqual(TokenFormatter.format(10_000_000), "10.0M")
    }

    func test_format_compact_handlesEdgeCases() {
        // Just under 1000
        XCTAssertEqual(TokenFormatter.format(999), "999")
        // Exactly 1000
        XCTAssertEqual(TokenFormatter.format(1000), "1.0k")
        // Just over 1000
        XCTAssertEqual(TokenFormatter.format(1001), "1.0k")
    }

    // MARK: - format() With Suffix Style Tests

    func test_format_withSuffix_formatsCorrectly() {
        XCTAssertEqual(TokenFormatter.format(500, style: .withSuffix), "500 tokens")
        XCTAssertEqual(TokenFormatter.format(1500, style: .withSuffix), "1.5K tokens")
        XCTAssertEqual(TokenFormatter.format(1_500_000, style: .withSuffix), "1.5M tokens")
    }

    // MARK: - format() Uppercase Style Tests

    func test_format_uppercase_formatsCorrectly() {
        XCTAssertEqual(TokenFormatter.format(500, style: .uppercase), "500")
        XCTAssertEqual(TokenFormatter.format(1500, style: .uppercase), "1.5K")
        XCTAssertEqual(TokenFormatter.format(1_500_000, style: .uppercase), "1.5M")
    }

    // MARK: - formatPair() Tests

    func test_formatPair_formatsInputOutput() {
        XCTAssertEqual(TokenFormatter.formatPair(input: 1000, output: 2000), "↓1.0k ↑2.0k")
        XCTAssertEqual(TokenFormatter.formatPair(input: 500, output: 1500), "↓500 ↑1.5k")
    }

    // MARK: - Int Extension Tests

    func test_intExtension_formattedTokenCount() {
        XCTAssertEqual(500.formattedTokenCount, "500")
        XCTAssertEqual(1500.formattedTokenCount, "1.5k")
        XCTAssertEqual(1_500_000.formattedTokenCount, "1.5M")
    }

    func test_intExtension_formattedTokensWithSuffix() {
        XCTAssertEqual(500.formattedTokensWithSuffix, "500 tokens")
        XCTAssertEqual(1500.formattedTokensWithSuffix, "1.5K tokens")
    }

    // MARK: - TokenUsage Cache Properties Tests

    func test_tokenUsage_formattedCacheRead_returnsNil_whenNilOrZero() {
        let usageNil = TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: nil, cacheCreationTokens: nil)
        XCTAssertNil(usageNil.formattedCacheRead)

        let usageZero = TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheCreationTokens: nil)
        XCTAssertNil(usageZero.formattedCacheRead)
    }

    func test_tokenUsage_formattedCacheRead_returnsFormatted_whenPositive() {
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: 20000, cacheCreationTokens: nil)
        XCTAssertEqual(usage.formattedCacheRead, "20.0k")
    }

    func test_tokenUsage_formattedCacheWrite_returnsFormatted_whenPositive() {
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: nil, cacheCreationTokens: 8000)
        XCTAssertEqual(usage.formattedCacheWrite, "8.0k")
    }

    func test_tokenUsage_hasCacheActivity_returnsFalse_whenNoCacheTokens() {
        let usageNil = TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: nil, cacheCreationTokens: nil)
        XCTAssertFalse(usageNil.hasCacheActivity)

        let usageZero = TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheCreationTokens: 0)
        XCTAssertFalse(usageZero.hasCacheActivity)
    }

    func test_tokenUsage_hasCacheActivity_returnsTrue_whenCacheRead() {
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: 20000, cacheCreationTokens: nil)
        XCTAssertTrue(usage.hasCacheActivity)
    }

    func test_tokenUsage_hasCacheActivity_returnsTrue_whenCacheWrite() {
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: nil, cacheCreationTokens: 5000)
        XCTAssertTrue(usage.hasCacheActivity)
    }

    func test_tokenUsage_hasCacheActivity_returnsTrue_whenBothCacheReadAndWrite() {
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: 18000, cacheCreationTokens: 2000)
        XCTAssertTrue(usage.hasCacheActivity)
        XCTAssertEqual(usage.formattedCacheRead, "18.0k")
        XCTAssertEqual(usage.formattedCacheWrite, "2.0k")
    }

    // MARK: - formatFullSession() Tests (includes cache tokens)

    func test_formatFullSession_noCacheTokens_returnsBasePair() {
        // No cache tokens - just returns the base pair
        let result = TokenFormatter.formatFullSession(input: 500, output: 63, cacheRead: 0, cacheWrite: 0)
        XCTAssertEqual(result, "↓500 ↑63")
    }

    func test_formatFullSession_cacheReadOnly_includesLightningBolt() {
        // Cache read only - shows ⚡ symbol
        let result = TokenFormatter.formatFullSession(input: 500, output: 63, cacheRead: 20300, cacheWrite: 0)
        XCTAssertEqual(result, "↓500 ↑63 ⚡20.3k")
    }

    func test_formatFullSession_cacheWriteOnly_includesPencil() {
        // Cache write only - shows ✏ symbol
        let result = TokenFormatter.formatFullSession(input: 500, output: 63, cacheRead: 0, cacheWrite: 8000)
        XCTAssertEqual(result, "↓500 ↑63 ✏8.0k")
    }

    func test_formatFullSession_bothCacheReadAndWrite_includesBoth() {
        // Both cache read and write
        let result = TokenFormatter.formatFullSession(input: 500, output: 63, cacheRead: 20000, cacheWrite: 8000)
        XCTAssertEqual(result, "↓500 ↑63 ⚡20.0k ✏8.0k")
    }

    func test_formatFullSession_largeNumbers_formatsCorrectly() {
        // Large numbers format correctly
        let result = TokenFormatter.formatFullSession(input: 100000, output: 25000, cacheRead: 1500000, cacheWrite: 500000)
        XCTAssertEqual(result, "↓100.0k ↑25.0k ⚡1.5M ✏500.0k")
    }

    func test_formatFullSession_nilValues_treatedAsZero() {
        // nil values should be treated as 0 (no cache display)
        let result = TokenFormatter.formatFullSession(input: 500, output: 63, cacheRead: nil, cacheWrite: nil)
        XCTAssertEqual(result, "↓500 ↑63")
    }

    // MARK: - SessionInfo.formattedTokens Tests

    func test_sessionInfo_formattedTokens_includesCacheWhenPresent() {
        // Create SessionInfo with cache tokens via JSON decoding
        let json = """
        {
            "sessionId": "test_session",
            "model": "claude-sonnet",
            "createdAt": "2024-01-01T00:00:00Z",
            "messageCount": 2,
            "inputTokens": 502,
            "outputTokens": 63,
            "cacheReadTokens": 20300,
            "cacheCreationTokens": 0,
            "cost": 0.03,
            "isActive": true
        }
        """.data(using: .utf8)!

        let session = try! JSONDecoder().decode(SessionInfo.self, from: json)
        XCTAssertEqual(session.formattedTokens, "↓502 ↑63 ⚡20.3k")
    }

    func test_sessionInfo_formattedTokens_noCacheWhenZero() {
        let json = """
        {
            "sessionId": "test_session",
            "model": "claude-sonnet",
            "createdAt": "2024-01-01T00:00:00Z",
            "messageCount": 2,
            "inputTokens": 502,
            "outputTokens": 63,
            "cacheReadTokens": 0,
            "cacheCreationTokens": 0,
            "cost": 0.03,
            "isActive": true
        }
        """.data(using: .utf8)!

        let session = try! JSONDecoder().decode(SessionInfo.self, from: json)
        XCTAssertEqual(session.formattedTokens, "↓502 ↑63")
    }

    func test_sessionInfo_formattedTokens_showsBothCacheTypes() {
        let json = """
        {
            "sessionId": "test_session",
            "model": "claude-sonnet",
            "createdAt": "2024-01-01T00:00:00Z",
            "messageCount": 2,
            "inputTokens": 502,
            "outputTokens": 63,
            "cacheReadTokens": 18000,
            "cacheCreationTokens": 2000,
            "cost": 0.03,
            "isActive": true
        }
        """.data(using: .utf8)!

        let session = try! JSONDecoder().decode(SessionInfo.self, from: json)
        XCTAssertEqual(session.formattedTokens, "↓502 ↑63 ⚡18.0k ✏2.0k")
    }
}
