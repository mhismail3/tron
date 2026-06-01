import Foundation
import os

/// Thread-safe wrapper for non-Sendable formatters.
/// Uses `OSAllocatedUnfairLock` to serialize access to formatters that are not safe
/// for concurrent reads (DateFormatter, RelativeDateTimeFormatter, ISO8601DateFormatter).
private struct LockedFormatter<F>: Sendable where F: AnyObject {
    private let lock: OSAllocatedUnfairLock<F>

    init(_ formatter: F) {
        self.lock = OSAllocatedUnfairLock(uncheckedState: formatter)
    }

    func withLock<R: Sendable>(_ body: @Sendable (F) -> R) -> R {
        lock.withLock { body($0) }
    }
}

/// Centralized ISO8601 date parsing and formatting with static formatter caching.
/// All formatters are protected by locks for thread-safe concurrent access.
enum DateParser: Sendable {

    // MARK: - Cached ISO8601 Formatters

    private static let isoWithFractional = LockedFormatter({
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }())

    private static let isoStandard = LockedFormatter({
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }())

    // MARK: - Cached Relative Formatters

    private static let relativeAbbreviatedFormatter = LockedFormatter({
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }())

    private static let relativeFullFormatter = LockedFormatter({
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }())

    // MARK: - Cached Display Formatters

    private static let mediumDateShortTime = LockedFormatter({
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }())

    private static let shortDateMediumTime = LockedFormatter({
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }())

    private static let shortTime = LockedFormatter({
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }())

    private static let mediumDate = LockedFormatter({
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }())

    private static let mediumDateTime = LockedFormatter({
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }())

    private static let dayOfWeekTime = LockedFormatter({
        let f = DateFormatter()
        f.dateFormat = "EEEE, h:mm a"
        return f
    }())

    private static let shortMonthDay = LockedFormatter({
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }())

    private static let shortMonthDayYear = LockedFormatter({
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }())

    private static let logTimestamp = LockedFormatter({
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }())

    private static let timeHMS = LockedFormatter({
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }())

    // MARK: - ISO8601 Output (Millis)

    /// Format a Date as ISO8601 with fractional seconds (millisecond precision).
    /// Used for client log ingestion timestamps.
    static func formatISO8601WithMillis(_ date: Date) -> String {
        isoWithFractional.withLock { $0.string(from: date) }
    }

    // MARK: - Date-Only Formatter

    private static let dateOnly = LockedFormatter({
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        return f
    }())

    // MARK: - Parsing

    /// Parse an ISO8601 date string, trying fractional seconds, standard, then date-only.
    /// Handles "2026-03-10T09:00:00Z", "2026-03-10T09:00:00.000Z", and "2026-03-10".
    static func parse(_ string: String) -> Date? {
        isoWithFractional.withLock { $0.date(from: string) }
            ?? isoStandard.withLock { $0.date(from: string) }
            ?? dateOnly.withLock { $0.date(from: string) }
    }

    /// Parse an ISO8601 date string, returning `Date()` if parsing fails.
    static func parseOrNow(_ string: String) -> Date {
        parse(string) ?? Date()
    }

    // MARK: - ISO8601 Output

    /// Format a Date as an ISO8601 string with fractional seconds.
    static func toISO8601(_ date: Date) -> String {
        isoWithFractional.withLock { $0.string(from: date) }
    }

    /// Current time as ISO8601 string with fractional seconds.
    static var now: String {
        isoWithFractional.withLock { $0.string(from: Date()) }
    }

    // MARK: - Relative Formatting

    /// Parse ISO8601 string -> abbreviated relative time (e.g., "2 hr. ago").
    /// Returns the input unchanged if parsing fails.
    static func relativeAbbreviated(_ isoString: String) -> String {
        guard let date = parse(isoString) else { return isoString }
        return relativeAbbreviatedFormatter.withLock { $0.localizedString(for: date, relativeTo: Date()) }
    }

    /// Date -> abbreviated relative time (e.g., "2 hr. ago").
    static func relativeAbbreviated(_ date: Date) -> String {
        relativeAbbreviatedFormatter.withLock { $0.localizedString(for: date, relativeTo: Date()) }
    }

    /// Date -> full relative time (e.g., "2 hours ago").
    static func relativeFull(_ date: Date) -> String {
        relativeFullFormatter.withLock { $0.localizedString(for: date, relativeTo: Date()) }
    }

    // MARK: - Display Formatting

    /// Parse ISO8601 -> "Jan 15, 2025 2:30 PM" (medium date, short time).
    /// Returns the input unchanged if parsing fails.
    static func mediumDateTime(_ isoString: String) -> String {
        guard let date = parse(isoString) else { return isoString }
        return mediumDateShortTime.withLock { $0.string(from: date) }
    }

    /// Parse ISO8601 -> "1/15/25, 2:30:45 PM" (short date, medium time).
    /// Returns the input unchanged if parsing fails.
    static func shortDateTime(_ isoString: String) -> String {
        guard let date = parse(isoString) else { return isoString }
        return shortDateMediumTime.withLock { $0.string(from: date) }
    }

    /// Format an ISO8601 date string as relative (<24h) or absolute (older).
    /// Returns the original string if parsing fails.
    static func formatRelativeOrAbsolute(_ dateString: String) -> String {
        guard let date = parse(dateString) else { return dateString }

        let now = Date()
        let interval = now.timeIntervalSince(date)

        if abs(interval) < 60 {
            return "now"
        }

        if interval < 86400 && interval >= 0 {
            return relativeFullFormatter.withLock { $0.localizedString(for: date, relativeTo: now) }
        }

        if Calendar.current.isDate(date, equalTo: now, toGranularity: .year) {
            return shortMonthDay.withLock { $0.string(from: date) }
        } else {
            return shortMonthDayYear.withLock { $0.string(from: date) }
        }
    }

    /// Compact relative format for dashboard cards: "2m ago", "3h ago", "Jan 5".
    static func formatCompactRelative(_ dateString: String) -> String {
        guard let date = parse(dateString) else { return dateString }

        let now = Date()
        let interval = now.timeIntervalSince(date)

        guard interval >= 0 else { return "now" }

        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        }

        if Calendar.current.isDate(date, equalTo: now, toGranularity: .year) {
            return shortMonthDay.withLock { $0.string(from: date) }
        } else {
            return shortMonthDayYear.withLock { $0.string(from: date) }
        }
    }

    // MARK: - Smart Formatting (Date extensions)

    /// "2:30 PM" — time only
    static func formatTime(_ date: Date) -> String {
        shortTime.withLock { $0.string(from: date) }
    }

    /// "Jan 15, 2025" — date only
    static func formatDate(_ date: Date) -> String {
        mediumDate.withLock { $0.string(from: date) }
    }

    /// "Jan 15, 2025, 2:30 PM" — date + time
    static func formatDateTime(_ date: Date) -> String {
        mediumDateTime.withLock { $0.string(from: date) }
    }

    /// "Tuesday, 2:30 PM" — day of week + time
    static func formatDayOfWeekTime(_ date: Date) -> String {
        dayOfWeekTime.withLock { $0.string(from: date) }
    }

    /// "14:30:05.123" — log timestamp with milliseconds
    static func formatLogTimestamp(_ date: Date) -> String {
        logTimestamp.withLock { $0.string(from: date) }
    }

    /// "14:30:05" — hours:minutes:seconds
    static func formatHMS(_ date: Date) -> String {
        timeHMS.withLock { $0.string(from: date) }
    }
}
