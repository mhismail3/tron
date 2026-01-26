import Foundation

// MARK: - Human-Readable Dates

extension CachedSession {
    // Cached formatters (creating these is expensive)
    // nonisolated(unsafe) because ISO8601DateFormatter is not Sendable, but we only read from them
    private static nonisolated(unsafe) let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static nonisolated(unsafe) let isoFormatterBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    var humanReadableCreatedAt: String {
        // Parse ISO date and format nicely
        if let date = Self.isoFormatterWithFractional.date(from: createdAt) {
            return date.humanReadable
        }
        // Try without fractional seconds
        if let date = Self.isoFormatterBasic.date(from: createdAt) {
            return date.humanReadable
        }
        return createdAt
    }

    var humanReadableLastActivity: String {
        if let date = Self.isoFormatterWithFractional.date(from: lastActivityAt) {
            return date.humanReadable
        }
        if let date = Self.isoFormatterBasic.date(from: lastActivityAt) {
            return date.humanReadable
        }
        return formattedDate
    }
}

extension Date {
    // Cached formatters (creating these is expensive)
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    var humanReadable: String {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.minute, .hour, .day], from: self, to: now)

        if let days = components.day, days > 0 {
            if days == 1 { return "Yesterday" }
            if days < 7 {
                return Self.dayFormatter.string(from: self)
            }
            return Self.dateFormatter.string(from: self)
        } else if let hours = components.hour, hours > 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else if let minutes = components.minute, minutes > 0 {
            return "\(minutes) min ago"
        }
        return "Just now"
    }
}
