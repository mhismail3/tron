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
}
