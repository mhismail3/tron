import Foundation

/// Per-preset bearer-token registry for the WebSocket auth header.
///
/// Each `ConnectionPreset` (server entry in `ConnectionSettingsPage`) gets
/// its own bearer token, stored in the iOS Keychain under
/// `com.tron.mobile.bearer.<presetId>`. Switching active presets changes
/// which token `WebSocketService` sends in the `Authorization: Bearer …`
/// header.
///
/// **Key type:** `ConnectionPreset.id` is `String` (server-driven labels are
/// stable across rename), so token storage keys on the raw string id rather
/// than a UUID. A preset without a token is unpaired: the first WS connect
/// attempt fails 401 and `ConnectionStatusPill` enters `.unauthorized`,
/// prompting the user to re-pair that server.
struct PresetTokenStore {
    /// Keychain service prefix for per-preset tokens. The Keychain account
    /// field carries the preset id.
    static let keychainServicePrefix = "com.tron.mobile.bearer"

    init() {}

    /// Store a bearer `token` for the preset with the given `id`. Overwrites
    /// any existing token for that preset. Throws on Keychain failure.
    func setToken(_ token: String, forPresetId id: String) throws {
        try makeItem(for: id).set(token)
    }

    /// Look up the stored bearer token for the given preset id, or `nil` if
    /// no token has been stored yet.
    func token(forPresetId id: String) -> String? {
        makeItem(for: id).get()
    }

    /// Remove the bearer token for a preset. No-op if absent.
    func remove(presetId id: String) throws {
        try makeItem(for: id).delete()
    }

    // MARK: - Internal helpers

    private func makeItem(for id: String) -> KeychainItem {
        KeychainItem(
            service: Self.keychainServicePrefix,
            account: id
        )
    }
}
