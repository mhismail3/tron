import Foundation

/// Durable per-server cursor store for engine stream subscriptions.
///
/// Cursors are keyed by the server origin, stream topic, optional
/// session/workspace scope, and filter hash. The server keeps connection-local
/// ack state; this store lets the app resume from the last dispatched event
/// after reconnect or app restart.
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
