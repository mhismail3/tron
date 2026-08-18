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

    static func relativeDescription(_ value: String, relativeTo reference: Date) -> String {
        guard let date = parse(value) else { return "" }
        return relative.string(for: date, relativeTo: reference)
    }
}
