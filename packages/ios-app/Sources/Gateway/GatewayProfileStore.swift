import Foundation
import Security

struct GatewayProfileDocument: Codable, Equatable, Sendable {
    let profiles: [GatewayProfile]
    let selectedProfileID: String?
}

protocol GatewayProfileMetadataStoring {
    func load() throws -> GatewayProfileDocument?
    func save(_ document: GatewayProfileDocument) throws
}

protocol GatewayTokenStoring {
    func save(_ token: String, profileID: String) throws
    func read(profileID: String) throws -> String?
    func delete(profileID: String) throws
}

@MainActor
final class GatewayProfileStore {
    private let metadata: any GatewayProfileMetadataStoring
    private let tokens: any GatewayTokenStoring

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            metadata: UserDefaultsGatewayProfileMetadataStore(defaults: defaults),
            tokens: KeychainGatewayTokenStore()
        )
    }

    init(metadata: any GatewayProfileMetadataStoring, tokens: any GatewayTokenStoring) {
        self.metadata = metadata
        self.tokens = tokens
    }

    var profiles: [GatewayProfile] { document.profiles }

    var selected: GatewayProfile? {
        let document = document
        return document.profiles.first { $0.id == document.selectedProfileID } ?? document.profiles.first
    }

    func save(_ profile: GatewayProfile, token: String) throws {
        guard profile.hasValidEndpoint else { throw GatewayProfileStoreError.invalidEndpoint }
        let previousDocument = document
        let previousToken = try tokens.read(profileID: profile.id)
        var values = previousDocument.profiles.filter { $0.id != profile.id }
        values.append(profile)
        let replacement = GatewayProfileDocument(profiles: values, selectedProfileID: profile.id)

        // Keychain upsert is atomic for an existing item. Metadata is committed
        // only after it succeeds; a metadata failure restores the exact prior
        // credential (or removes a newly-created credential).
        try tokens.save(token, profileID: profile.id)
        do {
            try metadata.save(replacement)
        } catch {
            do {
                if let previousToken { try tokens.save(previousToken, profileID: profile.id) }
                else { try tokens.delete(profileID: profile.id) }
            } catch let rollbackError {
                throw GatewayProfileStoreError.rollbackFailed(commit: error, rollback: rollbackError)
            }
            throw error
        }
    }

    func select(_ profile: GatewayProfile) {
        let current = document
        guard current.profiles.contains(where: { $0.id == profile.id }) else { return }
        try? metadata.save(GatewayProfileDocument(
            profiles: current.profiles,
            selectedProfileID: profile.id
        ))
    }

    func remove(_ profile: GatewayProfile) throws {
        let current = document
        let values = current.profiles.filter { $0.id != profile.id }
        let selectedID = current.selectedProfileID == profile.id
            ? values.first?.id
            : current.selectedProfileID
        let replacement = GatewayProfileDocument(profiles: values, selectedProfileID: selectedID)
        try metadata.save(replacement)
        do {
            try tokens.delete(profileID: profile.id)
        } catch {
            do {
                try metadata.save(current)
            } catch let rollbackError {
                throw GatewayProfileStoreError.rollbackFailed(commit: error, rollback: rollbackError)
            }
            throw error
        }
    }

    func token(for profile: GatewayProfile) -> String? {
        try? tokens.read(profileID: profile.id)
    }

    private var document: GatewayProfileDocument {
        guard let loaded = try? metadata.load() else {
            return GatewayProfileDocument(profiles: [], selectedProfileID: nil)
        }
        let profiles = loaded.profiles.filter(\.hasValidEndpoint)
        let selectedProfileID = profiles.contains { $0.id == loaded.selectedProfileID }
            ? loaded.selectedProfileID
            : profiles.first?.id
        let sanitized = GatewayProfileDocument(
            profiles: profiles,
            selectedProfileID: selectedProfileID
        )
        if sanitized != loaded { try? metadata.save(sanitized) }
        return sanitized
    }
}

enum GatewayProfileStoreError: Error {
    case invalidEndpoint
    case rollbackFailed(commit: Error, rollback: Error)
}

final class UserDefaultsGatewayProfileMetadataStore: GatewayProfileMetadataStoring {
    private let defaults: UserDefaults
    private let documentKey = "gatewayProfiles.v2"
    private let legacyProfilesKey = "gatewayProfiles.v1"
    private let legacySelectedKey = "selectedGateway.v1"

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() throws -> GatewayProfileDocument? {
        if let data = defaults.data(forKey: documentKey) {
            do {
                return try JSONDecoder.gateway.decode(GatewayProfileDocument.self, from: data)
            } catch {
                defaults.removeObject(forKey: documentKey)
            }
        }
        guard let legacy = defaults.data(forKey: legacyProfilesKey) else { return nil }
        do {
            let profiles = try JSONDecoder.gateway.decode([GatewayProfile].self, from: legacy)
            return GatewayProfileDocument(
                profiles: profiles,
                selectedProfileID: defaults.string(forKey: legacySelectedKey)
            )
        } catch {
            defaults.removeObject(forKey: legacyProfilesKey)
            defaults.removeObject(forKey: legacySelectedKey)
            return nil
        }
    }

    func save(_ document: GatewayProfileDocument) throws {
        let data = try JSONEncoder.gateway.encode(document)
        defaults.set(data, forKey: documentKey)
        defaults.removeObject(forKey: legacyProfilesKey)
        defaults.removeObject(forKey: legacySelectedKey)
    }
}

struct KeychainGatewayTokenStore: GatewayTokenStoring {
    private let service = "com.tron.mobile.gateway"

    func save(_ token: String, profileID: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
        ]
        let update: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }
        let addition = identity.merging(update) { _, replacement in replacement }
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    func read(profileID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(profileID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    struct KeychainError: Error { let status: OSStatus }
}
