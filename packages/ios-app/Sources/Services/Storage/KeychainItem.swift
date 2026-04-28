import Foundation
import Security

/// Generic Keychain wrapper for storing per-key string secrets.
///
/// Used by `PairedServerTokenStore` to store WebSocket bearer tokens keyed by
/// `PairedServer.id`. Items are stored as
/// `kSecClassGenericPassword` with `kSecAttrAccessibleAfterFirstUnlock` so
/// background reconnect works post-reboot before the user unlocks the device.
///
/// **Access group:** intentionally unset — items live in the app's default
/// Keychain access group (team-prefixed bundle id). The Share Extension
/// hands data off to the main app via the `group.com.tron.shared` App Group
/// container, so it does not need direct bearer-token access. If a future
/// extension needs the token directly, register a real
/// `keychain-access-groups` entry (`$(AppIdentifierPrefix)group.com.tron.shared`)
/// in entitlements and pass the group via `init(service:account:accessGroup:)`.
struct KeychainItem {
    /// Errors thrown by the Keychain wrapper.
    enum KeychainError: Swift.Error, Equatable {
        /// `SecItem*` returned a non-success, non-`errSecItemNotFound` status.
        /// Carries the raw `OSStatus` for diagnostics.
        case unhandled(OSStatus)
        /// String value could not be encoded as UTF-8 data, or stored data
        /// could not be decoded back to a string.
        case unexpectedItemData
    }

    let service: String
    let account: String
    /// Optional Keychain access group. Currently unused (see type doc).
    let accessGroup: String?

    init(service: String, account: String, accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Persist `value` to the Keychain. Replaces any existing item with the
    /// same `service` + `account`. Throws `KeychainError` on failure.
    func set(_ value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unexpectedItemData
        }

        // Try update first; fall back to add when no item exists yet.
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            updateAttributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unhandled(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandled(addStatus)
        }
    }

    /// Retrieve the stored value, or `nil` if no item exists for this
    /// `service` + `account` (or the read fails for any reason — callers treat
    /// missing and corrupt items the same way).
    func get() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete the stored item. No-op if absent. Throws `KeychainError` on a
    /// genuine Keychain failure that is not `errSecItemNotFound`.
    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
