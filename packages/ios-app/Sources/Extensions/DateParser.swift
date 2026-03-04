import Foundation

/// Centralized ISO8601 date parsing and formatting with static formatter caching.
/// Replaces ad-hoc ISO8601DateFormatter() / RelativeDateTimeFormatter() creation scattered across the codebase.
enum DateParser {

    // MARK: - Cached ISO8601 Formatters

    private nonisolated(unsafe) static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let isoStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Cached Relative Formatters

    private nonisolated(unsafe) static let relativeAbbreviatedFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private nonisolated(unsafe) static let relativeFullFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    // MARK: - Cached Display Formatters

    private static let mediumDateShortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let shortDateMediumTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    private static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private static let mediumDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let dayOfWeekTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, h:mm a"
        return f
    }()

    private static let shortMonthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let shortMonthDayYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static let logTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let timeHMS: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - ISO8601 Output (Millis)

    /// Format a Date as ISO8601 with fractional seconds (millisecond precision).
    /// Used for client log ingestion timestamps.
    static func formatISO8601WithMillis(_ date: Date) -> String {
        isoWithFractional.string(from: date)
    }

    // MARK: - Parsing

    /// Parse an ISO8601 date string, trying fractional seconds first then standard.
    static func parse(_ string: String) -> Date? {
        isoWithFractional.date(from: string) ?? isoStandard.date(from: string)
    }

    /// Parse an ISO8601 date string, returning `Date()` if parsing fails.
    static func parseOrNow(_ string: String) -> Date {
        parse(string) ?? Date()
    }

    // MARK: - ISO8601 Output

    /// Format a Date as an ISO8601 string with fractional seconds.
    static func toISO8601(_ date: Date) -> String {
        isoWithFractional.string(from: date)
    }

    /// Current time as ISO8601 string with fractional seconds.
    static var now: String {
        isoWithFractional.string(from: Date())
    }

    // MARK: - Relative Formatting

    /// Parse ISO8601 string → abbreviated relative time (e.g., "2 hr. ago").
    /// Returns the input unchanged if parsing fails.
    static func relativeAbbreviated(_ isoString: String) -> String {
        guard let date = parse(isoString) else { return isoString }
        return relativeAbbreviatedFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Date → abbreviated relative time (e.g., "2 hr. ago").
    static func relativeAbbreviated(_ date: Date) -> String {
        relativeAbbreviatedFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Date → full relative time (e.g., "2 hours ago").
    static func relativeFull(_ date: Date) -> String {
        relativeFullFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Display Formatting

    /// Parse ISO8601 → "Jan 15, 2025 2:30 PM" (medium date, short time).
    /// Returns the input unchanged if parsing fails.
    static func mediumDateTime(_ isoString: String) -> String {
        guard let date = parse(isoString) else { return isoString }
        return mediumDateShortTime.string(from: date)
    }

    /// Parse ISO8601 → "1/15/25, 2:30:45 PM" (short date, medium time).
    /// Returns the input unchanged if parsing fails.
    static func shortDateTime(_ isoString: String) -> String {
        guard let date = parse(isoString) else { return isoString }
        return shortDateMediumTime.string(from: date)
    }

    /// Format an ISO8601 date string as relative (<24h) or absolute (older).
    /// Returns the original string if parsing fails.
    static func formatRelativeOrAbsolute(_ dateString: String) -> String {
        guard let date = parse(dateString) else { return dateString }

        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 86400 && interval >= 0 {
            return relativeFullFormatter.localizedString(for: date, relativeTo: now)
        }

        if Calendar.current.isDate(date, equalTo: now, toGranularity: .year) {
            return shortMonthDay.string(from: date)
        } else {
            return shortMonthDayYear.string(from: date)
        }
    }

    // MARK: - Smart Formatting (Date extensions)

    /// "2:30 PM" — time only
    static func formatTime(_ date: Date) -> String {
        shortTime.string(from: date)
    }

    /// "Jan 15, 2025" — date only
    static func formatDate(_ date: Date) -> String {
        mediumDate.string(from: date)
    }

    /// "Jan 15, 2025, 2:30 PM" — date + time
    static func formatDateTime(_ date: Date) -> String {
        mediumDateTime.string(from: date)
    }

    /// "Tuesday, 2:30 PM" — day of week + time
    static func formatDayOfWeekTime(_ date: Date) -> String {
        dayOfWeekTime.string(from: date)
    }

    /// "14:30:05.123" — log timestamp with milliseconds
    static func formatLogTimestamp(_ date: Date) -> String {
        logTimestamp.string(from: date)
    }

    /// "14:30:05" — hours:minutes:seconds
    static func formatHMS(_ date: Date) -> String {
        timeHMS.string(from: date)
    }
}
