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
