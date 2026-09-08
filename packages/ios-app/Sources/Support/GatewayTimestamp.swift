import Foundation

private final class LockedRelativeDateFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    func string(for date: Date, relativeTo reference: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}

enum GatewayTimestamp {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    private static let relative = LockedRelativeDateFormatter()

    static func parse(_ value: String) -> Date? {
        if let date = try? fractional.parse(value) { return date }
        return try? wholeSeconds.parse(value)
    }

    static func string(from date: Date) -> String {
        date.formatted(wholeSeconds)
    }

    static func preciseString(from date: Date) -> String {
        date.formatted(fractional)
    }

    /// Compare parsed instants rather than ISO text. The textual tie-breaker
    /// keeps retention deterministic for equal instants and malformed input.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        if let left = parse(lhs), let right = parse(rhs), left != right {
            return left > right
        }
        if parse(lhs) != nil, parse(rhs) == nil { return true }
        if parse(lhs) == nil, parse(rhs) != nil { return false }
        return lhs > rhs
    }

    static func relativeDescription(_ value: String, relativeTo reference: Date) -> String {
        guard let date = parse(value) else { return "" }
        return relative.string(for: date, relativeTo: reference)
    }
}

/// Presentation-only copy for an invocation boundary. It intentionally accepts
/// only the producer's start timestamp: progress, result, and completion times
/// must never make a tool look newly invoked.
enum ToolInvocationTimestamp {
    static func date(_ value: String?) -> Date? {
        value.flatMap(GatewayTimestamp.parse)
    }

    static func text(
        for value: String?,
        relativeTo reference: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let date = date(value) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let dateStyle: Date.FormatStyle.DateStyle = calendar.isDate(date, inSameDayAs: reference)
            ? .omitted
            : .abbreviated
        var style = Date.FormatStyle(date: dateStyle, time: .shortened)
        style.locale = locale
        style.calendar = calendar
        style.timeZone = timeZone
        return date.formatted(style)
    }

    static func accessibilityText(
        for value: String?,
        relativeTo reference: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        text(for: value, relativeTo: reference, locale: locale, timeZone: timeZone)
            .map { "Invoked \($0)" }
    }
}
