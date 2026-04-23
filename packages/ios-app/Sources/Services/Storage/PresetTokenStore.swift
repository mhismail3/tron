import Foundation

/// Per-preset bearer-token registry for the WebSocket auth header.
///
/// **Status (Phase 0):** API skeleton — implementation lands in Phase 3 of
/// the onboarding plan (see project's plan dir, §C).
///
/// Each `ConnectionPreset` (server entry in `ConnectionSettingsPage`) gets
/// its own bearer token, stored in the iOS Keychain under
/// `com.tron.mobile.bearer.<presetId>`. Switching active presets changes
/// which token `WebSocketService` sends in the `Authorization: Bearer …`
/// header.
///
/// **Migration note:** when the iOS app upgrades and discovers existing
/// `connectionPresets` from server-side settings but no bearer tokens, the
/// first WS connect attempt fails 401 and `ConnectionStatusPill` enters the
/// `.unauthorized` state, prompting the user to re-pair. Per-preset tokens
/// are populated as the user re-pairs each server.
struct PresetTokenStore {
    /// Keychain service prefix for per-preset tokens.
    static let keychainServicePrefix = "com.tron.mobile.bearer"

    init() {}

    /// Store a bearer `token` for the preset with the given `id`. Overwrites
    /// any existing token for that preset. Throws on Keychain failure.
    func setToken(_ token: String, forPresetId id: UUID) throws {
        let item = KeychainItem(
            service: Self.keychainServicePrefix,
            account: id.uuidString
        )
        try item.set(token)
    }

    /// Look up the stored bearer token for the given preset id, or `nil` if
    /// no token has been stored yet (e.g. legacy preset from before bearer
    /// auth shipped).
    func token(forPresetId id: UUID) -> String? {
        let item = KeychainItem(
            service: Self.keychainServicePrefix,
            account: id.uuidString
        )
        return item.get()
    }

    /// Remove the bearer token for a preset. No-op if absent.
    func remove(presetId id: UUID) throws {
        let item = KeychainItem(
            service: Self.keychainServicePrefix,
            account: id.uuidString
        )
        try item.delete()
    }
}
