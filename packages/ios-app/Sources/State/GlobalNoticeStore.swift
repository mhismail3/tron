import Foundation

enum GlobalNoticeKey: Hashable {
    case gatewayRestart
    case packageProgress
    case sessionCatchUp
}

/// Disposable, presentation-only notice storage. Canonical outcomes remain on
/// the Gateway; this owner only bounds the small global capsule projection.
struct GlobalNoticeStore: Equatable {
    static let maximumCount = 8
    static let maximumMessageBytes = 4 * 1_024
    static let maximumTotalBytes = 16 * 1_024

    private struct Entry: Equatable {
        let key: GlobalNoticeKey?
        let message: String
    }

    private var entries: [Entry] = []

    var messages: [String] { entries.map(\.message) }
    var latest: String? { entries.last?.message }
    var totalBytes: Int { entries.reduce(0) { $0 + $1.message.utf8.count } }

    mutating func post(_ message: String, replacing key: GlobalNoticeKey? = nil) {
        let bounded = Self.boundedMessage(message)
        guard !bounded.isEmpty else { return }
        if let key {
            entries.removeAll { $0.key == key }
        } else if entries.last?.key == nil, entries.last?.message == bounded {
            return
        }
        entries.append(Entry(key: key, message: bounded))
        while entries.count > Self.maximumCount || totalBytes > Self.maximumTotalBytes {
            entries.removeFirst()
        }
    }

    mutating func remove(_ key: GlobalNoticeKey) {
        entries.removeAll { $0.key == key }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    private static func boundedMessage(_ message: String) -> String {
        guard message.utf8.count > maximumMessageBytes else { return message }
        let ellipsis = "…"
        let budget = maximumMessageBytes - ellipsis.utf8.count
        var result = ""
        result.reserveCapacity(budget)
        var byteCount = 0
        for character in message {
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= budget else { break }
            result.append(character)
            byteCount += bytes
        }
        return result + ellipsis
    }
}
