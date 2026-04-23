import Foundation
import Security

/// Generic Keychain wrapper for storing per-key string secrets.
///
/// **Status (Phase 0):** API skeleton only — implementation lands in
/// Phase 3 of the onboarding plan (see project's plan dir, §C).
///
/// Used by `PresetTokenStore` to store WebSocket bearer tokens keyed by
/// `ConnectionPreset.id`. Storage uses `kSecAttrAccessibleAfterFirstUnlock`
/// so background reconnect works post-reboot before user unlocks the device.
/// Access group `group.com.tron.shared` for forward-compat with the share
/// extension.
struct KeychainItem {
    let service: String
    let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// Persist `value` to the Keychain. Replaces any existing item with the
    /// same `service` + `account`. Throws on Keychain API failure.
    ///
    /// **Phase 0 stub:** returns without writing. Phase 3 wires the real
    /// `SecItemAdd` + `SecItemUpdate` calls.
    func set(_ value: String) throws {
        // Intentionally not implemented yet. Tests guard the contract via
        // PresetTokenStoreTests with `withKnownIssue` markers — they will
        // become real assertions in Phase 3.
    }

    /// Retrieve the stored value, or `nil` if no item exists for this
    /// `service` + `account`.
    ///
    /// **Phase 0 stub:** always returns `nil`.
    func get() -> String? {
        nil
    }

    /// Delete the stored item. No-op if absent. Throws on Keychain API
    /// failure.
    ///
    /// **Phase 0 stub:** returns without removing.
    func delete() throws {
        // Intentionally not implemented yet.
    }
}
