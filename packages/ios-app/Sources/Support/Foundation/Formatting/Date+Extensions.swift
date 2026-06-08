import Foundation

// MARK: - Date Extensions

extension Date {
    /// Returns a relative time string (e.g., "2 hr. ago")
    var relativeTime: String {
        DateParser.relativeAbbreviated(self)
    }

    /// Returns a formatted time string (e.g., "2:30 PM")
    var timeString: String {
        DateParser.formatTime(self)
    }

    /// Returns a formatted date string (e.g., "Jan 15, 2025")
    var dateString: String {
        DateParser.formatDate(self)
    }

    /// Returns a formatted date and time string
    var dateTimeString: String {
        DateParser.formatDateTime(self)
    }

    /// Returns an ISO8601 formatted string
    var iso8601String: String {
        DateParser.toISO8601(self)
    }

    /// Creates a date from an ISO8601 string
    static func fromISO8601(_ string: String) -> Date? {
        DateParser.parse(string)
    }

    /// Returns true if the date is today
    var isToday: Bool {
        Calendar.current.isDateInToday(self)
    }

    /// Returns true if the date is yesterday
    var isYesterday: Bool {
        Calendar.current.isDateInYesterday(self)
    }

    /// Returns true if the date is within the last week
    var isWithinLastWeek: Bool {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return self > weekAgo
    }

    /// Returns a smart formatted string based on how recent the date is
    var smartFormatted: String {
        if isToday {
            return timeString
        } else if isYesterday {
            return "Yesterday, \(timeString)"
        } else if isWithinLastWeek {
            return DateParser.formatDayOfWeekTime(self)
        } else {
            return dateTimeString
        }
    }
}

// MARK: - TimeInterval Extensions

extension TimeInterval {
    /// Converts milliseconds to a formatted duration string
    static func formatMilliseconds(_ ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        } else if ms < 60000 {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        } else {
            let seconds = ms / 1000
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            return "\(minutes)m \(remainingSeconds)s"
        }
    }

    /// Returns a formatted duration string
    var formattedDuration: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: "0:%02d", seconds)
        }
    }
}
