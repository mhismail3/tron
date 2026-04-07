import XCTest
@testable import TronMobile

/// Tests for TokenRecord.from(dict:) factory method
/// Verifies parsing from [String: Any] dictionaries (event payload format)
final class TokenRecordParsingTests: XCTestCase {

    // MARK: - Valid Parsing

    func testParseValidTokenRecord() {
        let dict = makeFullTokenRecordDict()

        let record = TokenRecord.from(dict: dict)

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.source.provider, "anthropic")
        XCTAssertEqual(record?.source.timestamp, "2024-01-15T10:30:00.000Z")
        XCTAssertEqual(record?.source.rawInputTokens, 502)
        XCTAssertEqual(record?.source.rawOutputTokens, 53)
        XCTAssertEqual(record?.source.rawCacheReadTokens, 17332)
        XCTAssertEqual(record?.source.rawCacheCreationTokens, 0)
        XCTAssertEqual(record?.computed.contextWindowTokens, 17834)
        XCTAssertEqual(record?.computed.newInputTokens, 17834)
        XCTAssertEqual(record?.computed.previousContextBaseline, 0)
        XCTAssertEqual(record?.computed.calculationMethod, "anthropic_cache_aware")
        XCTAssertEqual(record?.meta.turn, 1)
        XCTAssertEqual(record?.meta.sessionId, "sess_abc123")
        XCTAssertEqual(record?.meta.extractedAt, "2024-01-15T10:30:00.000Z")
        XCTAssertEqual(record?.meta.normalizedAt, "2024-01-15T10:30:00.001Z")
    }

    // MARK: - Missing Required Sections

    func testParseTokenRecordMissingSource() {
        var dict = makeFullTokenRecordDict()
        dict.removeValue(forKey: "source")

        XCTAssertNil(TokenRecord.from(dict: dict))
    }

    func testParseTokenRecordMissingComputed() {
        var dict = makeFullTokenRecordDict()
        dict.removeValue(forKey: "computed")

        XCTAssertNil(TokenRecord.from(dict: dict))
    }

    func testParseTokenRecordMissingMeta() {
        var dict = makeFullTokenRecordDict()
        dict.removeValue(forKey: "meta")

        XCTAssertNil(TokenRecord.from(dict: dict))
    }

    // MARK: - Nil / Empty Input

    func testParseTokenRecordNilDict() {
        XCTAssertNil(TokenRecord.from(dict: nil))
    }

    func testParseTokenRecordEmptyDict() {
        XCTAssertNil(TokenRecord.from(dict: [:]))
    }

    // MARK: - Partial Data (uses defaults)

    func testParseTokenRecordPartialSource() {
        var dict = makeFullTokenRecordDict()
        // Source with only provider — other fields should default
        dict["source"] = ["provider": "openai"] as [String: Any]

        let record = TokenRecord.from(dict: dict)

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.source.provider, "openai")
        XCTAssertEqual(record?.source.timestamp, "")
        XCTAssertEqual(record?.source.rawInputTokens, 0)
        XCTAssertEqual(record?.source.rawOutputTokens, 0)
        XCTAssertEqual(record?.source.rawCacheReadTokens, 0)
        XCTAssertEqual(record?.source.rawCacheCreationTokens, 0)
    }

    func testParseTokenRecordPartialMeta() {
        var dict = makeFullTokenRecordDict()
        // Meta with only sessionId — turn should default to 1
        dict["meta"] = ["sessionId": "sess_partial"] as [String: Any]

        let record = TokenRecord.from(dict: dict)

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.meta.turn, 1)
        XCTAssertEqual(record?.meta.sessionId, "sess_partial")
        XCTAssertEqual(record?.meta.extractedAt, "")
        XCTAssertEqual(record?.meta.normalizedAt, "")
    }

    func testParseTokenRecordPartialComputed() {
        var dict = makeFullTokenRecordDict()
        // Computed with only contextWindowTokens
        dict["computed"] = ["contextWindowTokens": 5000] as [String: Any]

        let record = TokenRecord.from(dict: dict)

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.computed.contextWindowTokens, 5000)
        XCTAssertEqual(record?.computed.newInputTokens, 0)
        XCTAssertEqual(record?.computed.previousContextBaseline, 0)
        XCTAssertEqual(record?.computed.calculationMethod, "")
    }

    // MARK: - Wrong Types (graceful defaults)

    func testParseTokenRecordWrongTypes() {
        var dict = makeFullTokenRecordDict()
        // Source fields as strings instead of ints — should default to 0
        dict["source"] = [
            "provider": "anthropic",
            "timestamp": "2024-01-15T10:30:00.000Z",
            "rawInputTokens": "not_a_number",
            "rawOutputTokens": "also_not",
            "rawCacheReadTokens": true,
            "rawCacheCreationTokens": 3.14
        ] as [String: Any]

        let record = TokenRecord.from(dict: dict)

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.source.rawInputTokens, 0)
        XCTAssertEqual(record?.source.rawOutputTokens, 0)
        XCTAssertEqual(record?.source.rawCacheReadTokens, 0)
        XCTAssertEqual(record?.source.rawCacheCreationTokens, 0)
    }

    // MARK: - Non-Dict Section Values

    func testParseTokenRecordSourceNotDict() {
        var dict = makeFullTokenRecordDict()
        dict["source"] = "not a dict"

        XCTAssertNil(TokenRecord.from(dict: dict))
    }

    func testParseTokenRecordComputedNotDict() {
        var dict = makeFullTokenRecordDict()
        dict["computed"] = 42

        XCTAssertNil(TokenRecord.from(dict: dict))
    }

    // MARK: - Extra Keys (ignored)

    func testParseTokenRecordExtraKeysIgnored() {
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

    // MARK: - Helpers

    private func makeFullTokenRecordDict() -> [String: Any] {
        [
            "source": [
                "provider": "anthropic",
                "timestamp": "2024-01-15T10:30:00.000Z",
                "rawInputTokens": 502,
                "rawOutputTokens": 53,
                "rawCacheReadTokens": 17332,
                "rawCacheCreationTokens": 0
            ] as [String: Any],
            "computed": [
                "contextWindowTokens": 17834,
                "newInputTokens": 17834,
                "previousContextBaseline": 0,
                "calculationMethod": "anthropic_cache_aware"
            ] as [String: Any],
            "meta": [
                "turn": 1,
                "sessionId": "sess_abc123",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            ] as [String: Any]
        ]
    }
}
