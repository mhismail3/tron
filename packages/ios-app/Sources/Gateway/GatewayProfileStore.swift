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
    private(set) var loadError: Error?
    private var cachedDocument: GatewayProfileDocument

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            metadata: UserDefaultsGatewayProfileMetadataStore(defaults: defaults),
            tokens: KeychainGatewayTokenStore()
        )
    }

    init(metadata: any GatewayProfileMetadataStoring, tokens: any GatewayTokenStoring) {
        self.metadata = metadata
        self.tokens = tokens
        let loaded: GatewayProfileDocument?
        do {
            loaded = try metadata.load()
        } catch {
            // Keep the cache bounded for callers that can render before recovery,
            // but retain the actual failure and never overwrite durable state.
            self.cachedDocument = Self.emptyDocument
            self.loadError = error
            return
        }
        let sanitized = Self.sanitize(loaded ?? Self.emptyDocument)
        self.cachedDocument = sanitized
        self.loadError = nil
        // Missing metadata is a valid first launch and is not materialized.
        // Repairs/migrations are persisted only for successfully admitted data.
        if let loaded, loaded != sanitized {
            do { try metadata.save(sanitized) }
            catch { self.loadError = error }
        }
    }

    var profiles: [GatewayProfile] { cachedDocument.profiles }

    var selected: GatewayProfile? {
        cachedDocument.profiles.first { $0.id == cachedDocument.selectedProfileID } ?? cachedDocument.profiles.first
    }

    /// Re-read and admit the durable document after a load failure. The error
    /// remains unresolved until both loading and any required repair succeed.
    func reload() throws {
        do {
            let loaded = try metadata.load()
            let sanitized = Self.sanitize(loaded ?? Self.emptyDocument)
            if let loaded, loaded != sanitized { try metadata.save(sanitized) }
            cachedDocument = sanitized
            loadError = nil
        } catch {
            loadError = error
            throw error
        }
    }

    /// Compatibility name for callers that already use the recovery path.
    func refresh() throws { try reload() }

    func save(_ profile: GatewayProfile, token: String, selecting: Bool = true) throws {
        try requireHealthyMetadata()
        guard profile.hasValidEndpoint else { throw GatewayProfileStoreError.invalidEndpoint }
        let previousDocument = cachedDocument
        let previousToken = try tokens.read(profileID: profile.id)
        var values = previousDocument.profiles.filter { $0.id != profile.id }
        values.append(profile)
        let replacement = Self.sanitize(GatewayProfileDocument(
            profiles: values,
            selectedProfileID: selecting ? profile.id : (previousDocument.selectedProfileID ?? values.first?.id)
        ))

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
        cachedDocument = replacement
    }

    func select(_ profile: GatewayProfile) throws {
        try requireHealthyMetadata()
        let current = cachedDocument
        guard current.profiles.contains(where: { $0.id == profile.id }) else {
            throw GatewayProfileStoreError.unknownProfile
        }
        let values = current.profiles.map { value in
            guard value.id == profile.id else { return value }
            var enabled = value
            enabled.isEnabled = true
            return enabled
        }
        let replacement = Self.sanitize(GatewayProfileDocument(profiles: values, selectedProfileID: profile.id))
        try metadata.save(replacement)
        cachedDocument = replacement
    }

    func update(_ profile: GatewayProfile) throws {
        try requireHealthyMetadata()
        guard profile.hasValidEndpoint else { throw GatewayProfileStoreError.invalidEndpoint }
        let current = cachedDocument
        guard current.profiles.contains(where: { $0.id == profile.id }) else {
            throw GatewayProfileStoreError.unknownProfile
        }
        let values = current.profiles.map { $0.id == profile.id ? profile : $0 }
        let replacement = Self.sanitize(GatewayProfileDocument(profiles: values, selectedProfileID: current.selectedProfileID))
        try metadata.save(replacement)
        cachedDocument = replacement
    }

    func setEnabled(_ enabled: Bool, for profile: GatewayProfile) throws {
        try requireHealthyMetadata()
        let current = cachedDocument
        guard current.profiles.contains(where: { $0.id == profile.id }) else {
            throw GatewayProfileStoreError.unknownProfile
        }
        if !enabled && current.selectedProfileID == profile.id {
            throw GatewayProfileStoreError.cannotDisableSelected
        }
        let values = current.profiles.map { value in
            guard value.id == profile.id else { return value }
            var replacement = value
            replacement.isEnabled = enabled
            return replacement
        }
        let replacement = Self.sanitize(GatewayProfileDocument(profiles: values, selectedProfileID: current.selectedProfileID))
        try metadata.save(replacement)
        cachedDocument = replacement
    }

    func remove(_ profile: GatewayProfile) throws {
        try requireHealthyMetadata()
        let current = cachedDocument
        let values = current.profiles.filter { $0.id != profile.id }
        let selectedID = current.selectedProfileID == profile.id
            ? values.first?.id
            : current.selectedProfileID
        let replacement = Self.sanitize(GatewayProfileDocument(profiles: values, selectedProfileID: selectedID))
        try metadata.save(replacement)
        do {
            try tokens.delete(profileID: profile.id)
        } catch {
            do {
                try metadata.save(Self.sanitize(current))
            } catch let rollbackError {
                throw GatewayProfileStoreError.rollbackFailed(commit: error, rollback: rollbackError)
            }
            throw error
        }
        cachedDocument = replacement
    }

    func token(for profile: GatewayProfile) -> String? {
        try? tokens.read(profileID: profile.id)
    }

    private func requireHealthyMetadata() throws {
        guard let loadError else { return }
        throw GatewayProfileStoreError.metadataLoadFailed(loadError)
    }

    private static let emptyDocument = GatewayProfileDocument(profiles: [], selectedProfileID: nil)

    private static func sanitize(_ loaded: GatewayProfileDocument) -> GatewayProfileDocument {
        let validProfiles = loaded.profiles.filter(\.hasValidEndpoint)
        let selectedProfileID = validProfiles.contains { $0.id == loaded.selectedProfileID }
            ? loaded.selectedProfileID
            : validProfiles.first?.id
        let profiles = validProfiles.map { profile in
            guard profile.id == selectedProfileID, !profile.isEnabled else { return profile }
            var enabled = profile
            enabled.isEnabled = true
            return enabled
        }
        return GatewayProfileDocument(profiles: profiles, selectedProfileID: selectedProfileID)
    }
}

enum GatewayProfileStoreError: Error {
    case metadataLoadFailed(Error)
    case invalidEndpoint
    case unknownProfile
    case cannotDisableSelected
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
            return try JSONDecoder.gateway.decode(GatewayProfileDocument.self, from: data)
        }
        guard let legacy = defaults.data(forKey: legacyProfilesKey) else { return nil }
        let profiles = try JSONDecoder.gateway.decode([GatewayProfile].self, from: legacy)
        return GatewayProfileDocument(
            profiles: profiles,
            selectedProfileID: defaults.string(forKey: legacySelectedKey)
        )
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
