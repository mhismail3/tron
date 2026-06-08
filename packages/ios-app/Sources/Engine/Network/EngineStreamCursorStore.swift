import Foundation

/// Durable per-server cursor store for engine stream subscriptions.
///
/// Cursors are keyed by the server origin, stream topic, optional
/// session/workspace scope, and filter hash. The server keeps connection-local
/// ack state; this store records delivered positions for diagnostics and ACK
/// coalescing. Session history is never restored from this store: the thin
/// client reconstructs session state with `session::reconstruct`, then uses
/// `events.session` only as a live future-event lane.
struct EngineStreamCursorKey: Hashable, Sendable {
    let serverOrigin: String
    let topic: String
    let sessionId: String?
    let workspaceId: String?
    let filterHash: String
}

final class EngineStreamCursorStore: @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let namespace = "tron.engine.stream.cursor"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func cursor(for key: EngineStreamCursorKey) -> EngineStreamCursor? {
        let raw = userDefaults.object(forKey: storageKey(for: key)) as? UInt64
        return raw.map(EngineStreamCursor.init(rawValue:))
    }

    func save(_ cursor: EngineStreamCursor, for key: EngineStreamCursorKey) {
        let existing = self.cursor(for: key)
        guard existing.map({ cursor > $0 }) ?? true else { return }
        userDefaults.set(cursor.rawValue, forKey: storageKey(for: key))
    }

    private func storageKey(for key: EngineStreamCursorKey) -> String {
        [
            namespace,
            escaped(key.serverOrigin),
            escaped(key.topic),
            escaped(key.sessionId ?? "_"),
            escaped(key.workspaceId ?? "_"),
            escaped(key.filterHash),
        ].joined(separator: ".")
    }

    private func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: ".", with: "%2E")
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: "/", with: "%2F")
    }
}

/// Coalesces stream acknowledgements per subscription.
///
/// Live session streams can deliver hundreds of small turn events in one
/// catch-up burst. The server only needs the highest delivered cursor for a
/// subscription, so the thin client records every cursor locally and sends a
/// bounded, coalesced ACK back to the engine.
struct EngineStreamAckCoalescer {
    private var latestBySubscription: [String: EngineStreamCursor] = [:]
    private var scheduledSubscriptions: Set<String> = []

    mutating func record(subscriptionId: String, cursor: EngineStreamCursor) -> Bool {
        if let existing = latestBySubscription[subscriptionId] {
            latestBySubscription[subscriptionId] = max(existing, cursor)
        } else {
            latestBySubscription[subscriptionId] = cursor
        }
        return scheduledSubscriptions.insert(subscriptionId).inserted
    }

    mutating func takeForFlush(subscriptionId: String) -> EngineStreamCursor? {
        latestBySubscription.removeValue(forKey: subscriptionId)
    }

    mutating func completeFlush(subscriptionId: String) -> Bool {
        scheduledSubscriptions.remove(subscriptionId)
        return latestBySubscription[subscriptionId] != nil
    }

    mutating func removeAll() {
        latestBySubscription.removeAll()
        scheduledSubscriptions.removeAll()
    }
}
