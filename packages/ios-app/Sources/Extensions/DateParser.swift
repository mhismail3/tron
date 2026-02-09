import Foundation

/// Centralized ISO8601 date parsing with static formatter caching.
/// Replaces ad-hoc ISO8601DateFormatter() creation scattered across the codebase.
enum DateParser {
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

    /// Parse an ISO8601 date string, trying fractional seconds first then standard.
    static func parse(_ string: String) -> Date? {
        isoWithFractional.date(from: string) ?? isoStandard.date(from: string)
    }

    /// Format an ISO8601 date string as relative (<24h) or absolute (older).
    /// Returns the original string if parsing fails.
    static func formatRelativeOrAbsolute(_ dateString: String) -> String {
        guard let date = parse(dateString) else { return dateString }

        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 86400 && interval >= 0 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: now)
        }

        let dateFormatter = DateFormatter()
        if Calendar.current.isDate(date, equalTo: now, toGranularity: .year) {
            dateFormatter.dateFormat = "MMM d"
        } else {
            dateFormatter.dateFormat = "MMM d, yyyy"
        }
        return dateFormatter.string(from: date)
    }
}
