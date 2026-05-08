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

    init() {}

    /// Store a bearer `token` for the paired server with the given `id`.
    /// Overwrites any existing token for that server. Throws on Keychain
    /// failure.
    func setToken(_ token: String, forServerId id: String) throws {
        try makeItem(for: id).set(token)
    }

    /// Look up the stored bearer token for the given paired server id, or
    /// `nil` if no token has been stored yet.
    func token(forServerId id: String) -> String? {
        makeItem(for: id).get()
    }

    /// Remove the bearer token for a paired server. No-op if absent.
    func remove(serverId id: String) throws {
        try makeItem(for: id).delete()
    }

    private func makeItem(for id: String) -> KeychainItem {
        KeychainItem(
            service: Self.keychainServicePrefix,
            account: id
        )
    }
}
