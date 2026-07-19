import Foundation

/// Per-paired-server bearer-token registry for the WebSocket auth header.
///
/// Each `PairedServer` gets its own bearer token, stored in the iOS Keychain
/// under `com.tron.mobile.bearer.<serverId>`. Switching the active server
/// changes which token `EngineConnection` sends in the
/// `Authorization: Bearer …` header.
struct PairedServerTokenStore {
    /// Keychain service prefix for per-server tokens. The Keychain account
    /// field carries the paired server id.
    static let keychainServicePrefix = "com.tron.mobile.bearer"

    struct Backend: Sendable {
        let setToken: @Sendable (_ token: String, _ serverId: String) throws -> Void
        let token: @Sendable (_ serverId: String) -> String?
        let remove: @Sendable (_ serverId: String) throws -> Void

        static let production = Backend(
            setToken: { token, id in try makeProductionItem(for: id).set(token) },
            token: { id in makeProductionItem(for: id).get() },
            remove: { id in try makeProductionItem(for: id).delete() }
        )

        private static func makeProductionItem(for id: String) -> KeychainItem {
            KeychainItem(service: PairedServerTokenStore.keychainServicePrefix, account: id)
        }
    }

    private let backend: Backend

    init(backend: Backend = .production) {
        self.backend = backend
    }

    /// Store a bearer `token` for the paired server with the given `id`.
    /// Overwrites any existing token for that server. Throws on Keychain
    /// failure.
    func setToken(_ token: String, forServerId id: String) throws {
        try backend.setToken(token, id)
    }

    /// Look up the stored bearer token for the given paired server id, or
    /// `nil` if no token has been stored yet.
    func token(forServerId id: String) -> String? {
        backend.token(id)
    }

    /// Remove the bearer token for a paired server. No-op if absent.
    func remove(serverId id: String) throws {
        try backend.remove(id)
    }
}
