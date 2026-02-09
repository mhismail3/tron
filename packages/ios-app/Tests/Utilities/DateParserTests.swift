import XCTest
@testable import TronMobile

final class DateParserTests: XCTestCase {

    // MARK: - Parsing

    func testParse_standardISO8601() {
        let date = DateParser.parse("2026-01-05T23:15:18Z")
        XCTAssertNotNil(date)
    }

    func testParse_withFractionalSeconds() {
        let date = DateParser.parse("2026-01-05T23:15:18.364Z")
        XCTAssertNotNil(date)
    }

    func testParse_withTimezoneOffset() {
        let date = DateParser.parse("2026-01-05T23:15:18+05:00")
        XCTAssertNotNil(date)
    }

    func testParse_emptyString_returnsNil() {
        XCTAssertNil(DateParser.parse(""))
    }

    func testParse_garbageString_returnsNil() {
        XCTAssertNil(DateParser.parse("not a date"))
    }

    func testParse_dateOnly_returnsNil() {
        XCTAssertNil(DateParser.parse("2026-01-05"))
    }

    func testParse_unixTimestamp_returnsNil() {
        XCTAssertNil(DateParser.parse("1735689318"))
    }

    // MARK: - Formatting

    func testFormatRelative_secondsAgo() {
        let date = Date().addingTimeInterval(-30)
        let isoString = ISO8601DateFormatter().string(from: date)
        let result = DateParser.formatRelativeOrAbsolute(isoString)
        // Should contain "seconds" or be a very recent relative time
        XCTAssertFalse(result.contains("Jan") || result.contains("Feb") || result.contains("Dec"),
                        "Within seconds should use relative format, got: \(result)")
    }

    func testFormatRelative_minutesAgo() {
        let date = Date().addingTimeInterval(-600) // 10 minutes ago
        let isoString = ISO8601DateFormatter().string(from: date)
        let result = DateParser.formatRelativeOrAbsolute(isoString)
        XCTAssertFalse(result.contains("Jan") || result.contains("Feb") || result.contains("Dec"),
                        "Within minutes should use relative format, got: \(result)")
    }

    func testFormatRelative_hoursAgo() {
        let date = Date().addingTimeInterval(-7200) // 2 hours ago
        let isoString = ISO8601DateFormatter().string(from: date)
        let result = DateParser.formatRelativeOrAbsolute(isoString)
        XCTAssertFalse(result.isEmpty, "Should produce a formatted string")
    }

    func testFormatAbsolute_oldDate() {
        // A date well in the past (>24h ago, same year check depends on current year)
        let result = DateParser.formatRelativeOrAbsolute("2025-06-15T10:00:00Z")
        // Should contain month abbreviation
        XCTAssertTrue(result.contains("Jun"), "Old date should show month, got: \(result)")
        XCTAssertTrue(result.contains("2025"), "Different year should include year, got: \(result)")
    }

    func testFormat_invalidString_returnsOriginal() {
        let result = DateParser.formatRelativeOrAbsolute("not-a-date")
        XCTAssertEqual(result, "not-a-date")
    }

    // MARK: - Static Formatter Caching (Smoke Test)

    func testParse_calledManyTimes_doesNotCrash() {
        for _ in 0..<1000 {
            _ = DateParser.parse("2026-01-05T23:15:18.364Z")
        }
        // If we get here without crashing, static caching works
    }

    // MARK: - Consistency

    func testParse_fractionalAndStandard_produceSameDate() {
        let withFractional = DateParser.parse("2026-01-05T23:15:18.000Z")
        let standard = DateParser.parse("2026-01-05T23:15:18Z")
        XCTAssertNotNil(withFractional)
        XCTAssertNotNil(standard)
        // Should be the same point in time (within 1 second tolerance)
        if let a = withFractional, let b = standard {
            XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970, accuracy: 1.0)
        }
    }
}
