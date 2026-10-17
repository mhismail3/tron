import Foundation

private final class LockedRelativeDateFormatter: @unchecked Sendable {
    /// Instants this close to the reference, or after it (gateway clock skew),
    /// read "now". `RelativeDateTimeFormatter` would show "in 0s"/"in 3s" and
    /// then flip to "1s ago", which reads as a glitch on a live row.
    static let nowWindow: TimeInterval = 5

    private let lock = NSLock()
    private let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// The locale's own word for the present instant ("now").
    private let now: String = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(fromTimeInterval: 0)
    }()

    package func string(for date: Date, relativeTo reference: Date) -> String {
        if reference.timeIntervalSince(date) < Self.nowWindow { return now }
        lock.lock()
        defer { lock.unlock() }
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}

package enum GatewayTimestamp {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    private static let relative = LockedRelativeDateFormatter()

    package static func parse(_ value: String) -> Date? {
        if let date = try? fractional.parse(value) { return date }
        return try? wholeSeconds.parse(value)
    }

    package static func string(from date: Date) -> String {
        date.formatted(wholeSeconds)
    }

    package static func preciseString(from date: Date) -> String {
        date.formatted(fractional)
    }

    /// Compare parsed instants rather than ISO text. The textual tie-breaker
    /// keeps retention deterministic for equal instants and malformed input.
    package static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        if let left = parse(lhs), let right = parse(rhs), left != right {
            return left > right
        }
        if parse(lhs) != nil, parse(rhs) == nil { return true }
        if parse(lhs) == nil, parse(rhs) != nil { return false }
        return lhs > rhs
    }

    package static func relativeDescription(_ value: String, relativeTo reference: Date) -> String {
        guard let date = parse(value) else { return "" }
        return relativeDescription(date, relativeTo: reference)
    }

    /// Abbreviated past-relative text ("12s ago", "3m ago"); "now" for the
    /// first few seconds and for future instants. Never future-tense.
    package static func relativeDescription(_ date: Date, relativeTo reference: Date) -> String {
        relative.string(for: date, relativeTo: reference)
    }

    /// The widest labels `relativeDescription` realistically produces, one per
    /// unit. A live row reserves the widest of these in its own font so the
    /// ticking label never changes the space left for neighbouring text.
    package static let relativeDescriptionWidthTemplates: [String] = {
        let reference = Date(timeIntervalSinceReferenceDate: 0)
        let day: TimeInterval = 86_400
        return [59, 59 * 60, 23 * 3_600, 6 * day, 4 * 7 * day, 11 * 30 * day, 10 * 365 * day]
            .map { relativeDescription(reference.addingTimeInterval(-$0), relativeTo: reference) }
    }()
}

/// Presentation-only copy for an invocation boundary. It intentionally accepts
/// only the producer's start timestamp: progress, result, and completion times
/// must never make a tool look newly invoked.
package enum ToolInvocationTimestamp {
    package static func date(_ value: String?) -> Date? {
        value.flatMap(GatewayTimestamp.parse)
    }

    package static func text(
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

    package static func accessibilityText(
        for value: String?,
        relativeTo reference: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        text(for: value, relativeTo: reference, locale: locale, timeZone: timeZone)
            .map { "Invoked \($0)" }
    }
}
