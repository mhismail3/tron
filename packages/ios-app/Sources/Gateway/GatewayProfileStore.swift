import Foundation
import Security

@MainActor
final class GatewayProfileStore {
    private let defaults: UserDefaults
    private let profilesKey = "gatewayProfiles.v1"
    private let selectedKey = "selectedGateway.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var profiles: [GatewayProfile] {
        guard let data = defaults.data(forKey: profilesKey) else { return [] }
        return (try? JSONDecoder.gateway.decode([GatewayProfile].self, from: data)) ?? []
    }

    var selected: GatewayProfile? {
        let id = defaults.string(forKey: selectedKey)
        return profiles.first { $0.id == id } ?? profiles.first
    }

    func save(_ profile: GatewayProfile, token: String) throws {
        var values = profiles.filter { $0.id != profile.id }
        values.append(profile)
        defaults.set(try JSONEncoder.gateway.encode(values), forKey: profilesKey)
        defaults.set(profile.id, forKey: selectedKey)
        try GatewayTokenStore.save(token, profileID: profile.id)
    }

    func select(_ profile: GatewayProfile) { defaults.set(profile.id, forKey: selectedKey) }

    func remove(_ profile: GatewayProfile) {
        let values = profiles.filter { $0.id != profile.id }
        defaults.set(try? JSONEncoder.gateway.encode(values), forKey: profilesKey)
        GatewayTokenStore.delete(profileID: profile.id)
        if selected?.id == profile.id { defaults.set(values.first?.id, forKey: selectedKey) }
    }

    func token(for profile: GatewayProfile) -> String? { GatewayTokenStore.read(profileID: profile.id) }
}

enum GatewayTokenStore {
    private static let service = "com.tron.mobile.gateway"

    static func save(_ token: String, profileID: String) throws {
        delete(profileID: profileID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func read(profileID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(profileID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
        ]
        SecItemDelete(query as CFDictionary)
    }

    struct KeychainError: Error { let status: OSStatus }
}
