import CryptoKit
import Foundation
import MacTerminalSSH
import Security

struct MacTerminalEnrollment: Codable, Equatable, Sendable {
    let machineID: String
    let deviceID: String
    let endpoint: MacTerminalEndpoint
    let publicKey: String
    let enrolledAt: Date
}

@MainActor
final class MacTerminalEnrollmentStore {
    private let defaults: UserDefaults
    private static let enrollmentsKey = "macTerminal.enrollments.v1"
    private static let keychainService = "com.tron.mobile.mac-terminal"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func enrollment(machineID: String) throws -> MacTerminalEnrollment? { try all()[machineID] }

    func save(_ enrollment: MacTerminalEnrollment) throws {
        var values = try all()
        values[enrollment.machineID] = enrollment
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.enrollmentsKey) }
    }

    func remove(machineID: String) throws {
        var values = try all()
        values.removeValue(forKey: machineID)
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.enrollmentsKey) }
        let status = SecItemDelete(keyQuery(machineID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MacTerminalKeyError(status: status) }
    }

    func key(machineID: String) throws -> MacTerminalPrivateKey {
        if let stored = try storedKey(machineID) { return stored }
        let (key, representation) = try Self.makeKey()
        var item = keyQuery(machineID)
        item[kSecValueData as String] = representation
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw MacTerminalKeyError(status: status) }
        return key
    }

    func existingKey(machineID: String) throws -> MacTerminalPrivateKey? { try storedKey(machineID) }

    private func all() throws -> [String: MacTerminalEnrollment] {
        guard let data = defaults.data(forKey: Self.enrollmentsKey) else { return [:] }
        return try JSONDecoder().decode([String: MacTerminalEnrollment].self, from: data)
    }

    private func keyQuery(_ machineID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.keychainService,
         kSecAttrAccount as String: machineID]
    }

    private func storedKey(_ machineID: String) throws -> MacTerminalPrivateKey? {
        var query = keyQuery(machineID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw MacTerminalKeyError(status: status) }
        return try Self.restoreKey(data)
    }

    #if targetEnvironment(simulator)
    private static func makeKey() throws -> (MacTerminalPrivateKey, Data) {
        let key = P256.Signing.PrivateKey()
        return (.software(key), key.rawRepresentation)
    }

    private static func restoreKey(_ data: Data) throws -> MacTerminalPrivateKey {
        .software(try P256.Signing.PrivateKey(rawRepresentation: data))
    }
    #else
    private static func makeKey() throws -> (MacTerminalPrivateKey, Data) {
        guard SecureEnclave.isAvailable else { throw MacTerminalKeyError(status: errSecUnimplemented) }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error
        ) else { throw error!.takeRetainedValue() as Error }
        let key = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: access)
        return (.secureEnclave(key), key.dataRepresentation)
    }

    private static func restoreKey(_ data: Data) throws -> MacTerminalPrivateKey {
        .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data))
    }
    #endif
}

struct MacTerminalKeyError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "This iPhone could not use its Mac Terminal key (Keychain status \(status))."
    }
}
