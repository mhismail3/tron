import Testing
import Foundation

@testable import TronMobile

@Suite("DateParser Caching Tests")
struct DateParserCachingTests {

    // MARK: - parse (regression)

    @Test("parse returns date for valid ISO8601 with fractional seconds")
    func parseValidFractional() {
        let date = DateParser.parse("2026-01-15T10:30:00.123Z")
        #expect(date != nil)
    }

    @Test("parse returns date for valid ISO8601 without fractional seconds")
    func parseValidStandard() {
        let date = DateParser.parse("2026-01-15T10:30:00Z")
        #expect(date != nil)
    }

    @Test("parse returns nil for invalid string")
    func parseInvalid() {
        #expect(DateParser.parse("not-a-date") == nil)
    }

    // MARK: - parseOrNow

    @Test("parseOrNow returns date for valid string")
    func parseOrNowValid() {
        let date = DateParser.parseOrNow("2026-01-15T10:30:00.123Z")
        let calendar = Calendar.current
        #expect(calendar.component(.year, from: date) == 2026)
    }

    @Test("parseOrNow returns current date for invalid string")
    func parseOrNowInvalid() {
        let before = Date()
        let date = DateParser.parseOrNow("garbage")
        let after = Date()
        #expect(date >= before && date <= after)
    }

    // MARK: - toISO8601

    @Test("toISO8601 roundtrips through parse")
    func toISO8601Roundtrip() {
        let original = Date()
        let iso = DateParser.toISO8601(original)
        let parsed = DateParser.parse(iso)
        #expect(parsed != nil)
        // Within 1 second tolerance (fractional seconds rounding)
        #expect(abs(parsed!.timeIntervalSince(original)) < 1.0)
    }

    @Test("now returns parseable ISO8601 string")
    func nowIsParseable() {
        let iso = DateParser.now
        #expect(DateParser.parse(iso) != nil)
    }

    // MARK: - relativeAbbreviated (String)

    @Test("relativeAbbreviated with valid ISO8601 returns non-empty string")
    func relativeAbbreviatedValid() {
        let result = DateParser.relativeAbbreviated("2026-01-15T10:30:00.123Z")
        #expect(!result.isEmpty)
    }

    @Test("relativeAbbreviated with invalid string returns input unchanged")
    func relativeAbbreviatedInvalid() {
        let input = "not-a-date"
        #expect(DateParser.relativeAbbreviated(input) == input)
    }

    // MARK: - relativeAbbreviated (Date)

    @Test("relativeAbbreviated with recent Date returns relative string")
    func relativeAbbreviatedDate() {
        let fiveMinutesAgo = Date().addingTimeInterval(-300)
        let result = DateParser.relativeAbbreviated(fiveMinutesAgo)
        #expect(!result.isEmpty)
    }

    // MARK: - relativeFull

    @Test("relativeFull with recent Date returns relative string")
    func relativeFullDate() {
        let fiveMinutesAgo = Date().addingTimeInterval(-300)
        let result = DateParser.relativeFull(fiveMinutesAgo)
        #expect(!result.isEmpty)
        #expect(result != "not-a-date")
    }

    // MARK: - mediumDateTime

    @Test("mediumDateTime with valid ISO8601 returns formatted string")
    func mediumDateTimeValid() {
        let result = DateParser.mediumDateTime("2026-01-15T10:30:00.123Z")
        #expect(!result.isEmpty)
        #expect(result != "2026-01-15T10:30:00.123Z")
    }

    @Test("mediumDateTime with invalid string returns input")
    func mediumDateTimeInvalid() {
        let input = "not-a-date"
        #expect(DateParser.mediumDateTime(input) == input)
    }

    // MARK: - shortDateTime

    @Test("shortDateTime with valid ISO8601 returns formatted string")
    func shortDateTimeValid() {
        let result = DateParser.shortDateTime("2026-01-15T10:30:00.123Z")
        #expect(!result.isEmpty)
        #expect(result != "2026-01-15T10:30:00.123Z")
    }

    @Test("shortDateTime with invalid string returns input")
    func shortDateTimeInvalid() {
        let input = "garbage"
        #expect(DateParser.shortDateTime(input) == input)
    }

    // MARK: - formatRelativeOrAbsolute (regression)

    @Test("formatRelativeOrAbsolute with invalid returns original string")
    func formatRelativeOrAbsoluteInvalid() {
        let input = "not-a-date"
        #expect(DateParser.formatRelativeOrAbsolute(input) == input)
    }

    // MARK: - Smart formatting helpers

    @Test("formatTime returns time string")
    func formatTime() {
        let date = Date()
        let result = DateParser.formatTime(date)
        #expect(!result.isEmpty)
    }

    @Test("formatDate returns date string")
    func formatDate() {
        let date = Date()
        let result = DateParser.formatDate(date)
        #expect(!result.isEmpty)
    }

    @Test("formatDateTime returns datetime string")
    func formatDateTime() {
        let date = Date()
        let result = DateParser.formatDateTime(date)
        #expect(!result.isEmpty)
    }

    @Test("formatDayOfWeekTime returns day + time string")
    func formatDayOfWeekTime() {
        let date = Date()
        let result = DateParser.formatDayOfWeekTime(date)
        #expect(!result.isEmpty)
    }
}
