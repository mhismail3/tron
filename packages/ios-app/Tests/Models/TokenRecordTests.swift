import XCTest
@testable import TronMobile

/// Tests for TokenRecord JSON parsing
/// Verifies iOS correctly parses the agent's tokenRecord wire format
final class TokenRecordTests: XCTestCase {

    // MARK: - JSON Decoding Tests

    func testDecodesCompleteTokenRecord() throws {
        let json = """
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
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(TokenRecord.self, from: json)

        // Verify source
        XCTAssertEqual(record.source.provider, "anthropic")
        XCTAssertEqual(record.source.rawInputTokens, 502)
        XCTAssertEqual(record.source.rawOutputTokens, 53)
        XCTAssertEqual(record.source.rawCacheReadTokens, 17332)
        XCTAssertEqual(record.source.rawCacheCreationTokens, 0)

        // Verify computed
        XCTAssertEqual(record.computed.contextWindowTokens, 17834)
        XCTAssertEqual(record.computed.newInputTokens, 17834)
        XCTAssertEqual(record.computed.previousContextBaseline, 0)
        XCTAssertEqual(record.computed.calculationMethod, "anthropic_cache_aware")

        // Verify meta
        XCTAssertEqual(record.meta.turn, 1)
        XCTAssertEqual(record.meta.sessionId, "sess_abc123")
    }

    func testDecodesOpenAITokenRecord() throws {
        let json = """
        {
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
                "sessionId": "sess_xyz789",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            }
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(TokenRecord.self, from: json)

        XCTAssertEqual(record.source.provider, "openai")
        XCTAssertEqual(record.computed.contextWindowTokens, 5000)
        XCTAssertEqual(record.computed.newInputTokens, 1000)
        XCTAssertEqual(record.computed.calculationMethod, "direct")
    }

    func testDecodesGoogleTokenRecord() throws {
        let json = """
        {
            "source": {
                "provider": "google",
                "timestamp": "2024-01-15T10:30:00.000Z",
                "rawInputTokens": 8000,
                "rawOutputTokens": 300,
                "rawCacheReadTokens": 0,
                "rawCacheCreationTokens": 0
            },
            "computed": {
                "contextWindowTokens": 8000,
                "newInputTokens": 8000,
                "previousContextBaseline": 0,
                "calculationMethod": "direct"
            },
            "meta": {
                "turn": 1,
                "sessionId": "sess_google",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            }
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(TokenRecord.self, from: json)

        XCTAssertEqual(record.source.provider, "google")
        XCTAssertEqual(record.computed.contextWindowTokens, 8000)
    }

    func testDecodesWithCacheCreationTokens() throws {
        // Test case where cache is being written (billing indicator)
        let json = """
        {
            "source": {
                "provider": "anthropic",
                "timestamp": "2024-01-15T10:30:00.000Z",
                "rawInputTokens": 500,
                "rawOutputTokens": 100,
                "rawCacheReadTokens": 0,
                "rawCacheCreationTokens": 8000
            },
            "computed": {
                "contextWindowTokens": 500,
                "newInputTokens": 500,
                "previousContextBaseline": 0,
                "calculationMethod": "anthropic_cache_aware"
            },
            "meta": {
                "turn": 1,
                "sessionId": "sess_cache",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            }
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(TokenRecord.self, from: json)

        // cacheCreationTokens is billing info, NOT added to context
        XCTAssertEqual(record.source.rawCacheCreationTokens, 8000)
        XCTAssertEqual(record.computed.contextWindowTokens, 500) // NOT 8500
    }

    // MARK: - TokenSource Tests

    func testTokenSourceTotalTokens() throws {
        let json = """
        {
            "provider": "anthropic",
            "timestamp": "2024-01-15T10:30:00.000Z",
            "rawInputTokens": 500,
            "rawOutputTokens": 100,
            "rawCacheReadTokens": 0,
            "rawCacheCreationTokens": 0
        }
        """.data(using: .utf8)!

        let source = try JSONDecoder().decode(TokenSource.self, from: json)

        XCTAssertEqual(source.totalTokens, 600) // 500 + 100
    }

    // MARK: - Equatable Tests

    func testTokenRecordEquality() throws {
        let json = """
        {
            "source": {
                "provider": "anthropic",
                "timestamp": "2024-01-15T10:30:00.000Z",
                "rawInputTokens": 500,
                "rawOutputTokens": 100,
                "rawCacheReadTokens": 0,
                "rawCacheCreationTokens": 0
            },
            "computed": {
                "contextWindowTokens": 500,
                "newInputTokens": 500,
                "previousContextBaseline": 0,
                "calculationMethod": "anthropic_cache_aware"
            },
            "meta": {
                "turn": 1,
                "sessionId": "sess_test",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            }
        }
        """.data(using: .utf8)!

        let record1 = try JSONDecoder().decode(TokenRecord.self, from: json)
        let record2 = try JSONDecoder().decode(TokenRecord.self, from: json)

        XCTAssertEqual(record1, record2)
    }

    // MARK: - Separate Cache Read/Write Formatting

    func testFormattedCacheReadSeparate() throws {
        let json = """
        {
            "source": {
                "provider": "anthropic",
                "timestamp": "2024-01-15T10:30:00.000Z",
                "rawInputTokens": 10,
                "rawOutputTokens": 261,
                "rawCacheReadTokens": 12561,
                "rawCacheCreationTokens": 498
            },
            "computed": {
                "contextWindowTokens": 12571,
                "newInputTokens": 10,
                "previousContextBaseline": 12561,
                "calculationMethod": "anthropic_cache_aware"
            },
            "meta": {
                "turn": 1,
                "sessionId": "sess_test",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            }
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(TokenRecord.self, from: json)

        // formattedCacheRead should return formatted cache read tokens
        XCTAssertNotNil(record.formattedCacheRead)
        XCTAssertEqual(record.formattedCacheRead, 12561.formattedTokenCount)
    }

    func testFormattedCacheWriteSeparate() throws {
        let json = """
        {
            "source": {
                "provider": "anthropic",
                "timestamp": "2024-01-15T10:30:00.000Z",
                "rawInputTokens": 10,
                "rawOutputTokens": 261,
                "rawCacheReadTokens": 12561,
                "rawCacheCreationTokens": 498
            },
            "computed": {
                "contextWindowTokens": 12571,
                "newInputTokens": 10,
                "previousContextBaseline": 12561,
                "calculationMethod": "anthropic_cache_aware"
            },
            "meta": {
                "turn": 1,
                "sessionId": "sess_test",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            }
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(TokenRecord.self, from: json)

        // formattedCacheWrite should return formatted cache creation tokens
        XCTAssertNotNil(record.formattedCacheWrite)
        XCTAssertEqual(record.formattedCacheWrite, 498.formattedTokenCount)
    }

    func testFormattedCacheReadZeroReturnsNil() throws {
        let json = """
        {
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
                "newInputTokens": 5000,
                "previousContextBaseline": 0,
                "calculationMethod": "direct"
            },
            "meta": {
                "turn": 1,
                "sessionId": "sess_test",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            }
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(TokenRecord.self, from: json)

        XCTAssertNil(record.formattedCacheRead, "Zero cache read should return nil")
    }

    func testFormattedCacheWriteZeroReturnsNil() throws {
        let json = """
        {
            "source": {
                "provider": "anthropic",
                "timestamp": "2024-01-15T10:30:00.000Z",
                "rawInputTokens": 500,
                "rawOutputTokens": 100,
                "rawCacheReadTokens": 17332,
                "rawCacheCreationTokens": 0
            },
            "computed": {
                "contextWindowTokens": 17832,
                "newInputTokens": 500,
                "previousContextBaseline": 17332,
                "calculationMethod": "anthropic_cache_aware"
            },
            "meta": {
                "turn": 2,
                "sessionId": "sess_test",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            }
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(TokenRecord.self, from: json)

        XCTAssertNil(record.formattedCacheWrite, "Zero cache write should return nil")
        XCTAssertNotNil(record.formattedCacheRead, "Non-zero cache read should still work")
    }

    // MARK: - Edge Cases

    func testDecodesWithZeroTokens() throws {
        // Edge case: empty response
        let json = """
        {
            "source": {
                "provider": "anthropic",
                "timestamp": "2024-01-15T10:30:00.000Z",
                "rawInputTokens": 0,
                "rawOutputTokens": 0,
                "rawCacheReadTokens": 0,
                "rawCacheCreationTokens": 0
            },
            "computed": {
                "contextWindowTokens": 0,
                "newInputTokens": 0,
                "previousContextBaseline": 0,
                "calculationMethod": "anthropic_cache_aware"
            },
            "meta": {
                "turn": 1,
                "sessionId": "sess_empty",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            }
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(TokenRecord.self, from: json)

        XCTAssertEqual(record.source.rawInputTokens, 0)
        XCTAssertEqual(record.computed.contextWindowTokens, 0)
    }

    func testDecodesLargeTokenCounts() throws {
        // Edge case: large context (close to limit)
        let json = """
        {
            "source": {
                "provider": "anthropic",
                "timestamp": "2024-01-15T10:30:00.000Z",
                "rawInputTokens": 190000,
                "rawOutputTokens": 5000,
                "rawCacheReadTokens": 0,
                "rawCacheCreationTokens": 0
            },
            "computed": {
                "contextWindowTokens": 190000,
                "newInputTokens": 1000,
                "previousContextBaseline": 189000,
                "calculationMethod": "anthropic_cache_aware"
            },
            "meta": {
                "turn": 50,
                "sessionId": "sess_large",
                "extractedAt": "2024-01-15T10:30:00.000Z",
                "normalizedAt": "2024-01-15T10:30:00.001Z"
            }
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(TokenRecord.self, from: json)

        XCTAssertEqual(record.source.rawInputTokens, 190000)
        XCTAssertEqual(record.computed.contextWindowTokens, 190000)
        XCTAssertEqual(record.meta.turn, 50)
    }
}
