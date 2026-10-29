import CryptoKit
import Foundation
import MacTerminalSSH
import Security

/// Mac Terminal's local state on this iPhone (README "Mac Terminal"): for each
/// paired Mac, the client key and what enrollment learned from its Gateway.
/// Both are read without the Gateway, which is the point of the feature.
///
/// - The key is a Secure Enclave P-256 key. Only its Secure Enclave-wrapped
///   `dataRepresentation` is stored, in this device's Keychain; it cannot be
///   used on any other device and the private key is never exported. The
///   Simulator has no Secure Enclave, so there (and only there) the key is a
///   software key in the same Keychain item.
/// - The enrollment (MagicDNS name, Tailscale addresses, user, pinned host
///   keys) is not secret and lives in this app's defaults. Host keys are pinned
///   once, at enrollment; nothing replaces them silently.
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

    /// Forgets the enrollment and destroys the key: a later enrollment makes a new one.
    func remove(machineID: String) throws {
        var values = try all()
        values.removeValue(forKey: machineID)
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.enrollmentsKey) }
        let status = SecItemDelete(keyQuery(machineID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MacTerminalKeyError(status: status) }
    }

    /// This Mac's client key, created on first use.
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

    /// The existing key only; nil before enrollment created one.
    func existingKey(machineID: String) throws -> MacTerminalPrivateKey? { try storedKey(machineID) }

    /// Approved forward-only retirement. Edit the original bytes, not a decoded
    /// enrollment: re-encoding would change pins' spelling and unknown fields.
    /// The backup is completed and checked before the first defaults mutation.
    private func retireHostCommand() throws {
        let marker = "macTerminal.hostCommandRetired.v1"
        guard !defaults.bool(forKey: marker) else { return }
        if let original = defaults.data(forKey: Self.enrollmentsKey) {
            var retirement = EnrollmentFieldRetirement(original)
            if let rewritten = try retirement.removingHostCommand() {
                let backup = URL.applicationSupportDirectory.appending(path: "MacTerminal/enrollments.v1-before-host-command-removal.json")
                if FileManager.default.fileExists(atPath: backup.path) {
                    guard try Data(contentsOf: backup) == original else { throw CocoaError(.fileReadCorruptFile) }
                } else {
                    try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try original.write(to: backup, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                guard try Data(contentsOf: backup) == original else { throw CocoaError(.fileReadCorruptFile) }
                defaults.set(rewritten, forKey: Self.enrollmentsKey)
                guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        defaults.set(true, forKey: marker)
        guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
    }

    private func all() throws -> [String: MacTerminalEnrollment] {
        try retireHostCommand()
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

/// A JSON byte editor, not a legacy enrollment decoder. Only the obsolete
/// endpoint property and its separator are removed; every surviving byte is copied.
private struct EnrollmentFieldRetirement {
    private let bytes: [UInt8]
    private var index = 0
    private var removals: [Range<Int>] = []

    init(_ data: Data) { bytes = Array(data) }

    mutating func removingHostCommand() throws -> Data? {
        guard try JSONSerialization.jsonObject(with: Data(bytes)) is [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try value(path: [], depth: 0)
        guard !removals.isEmpty else { return nil }
        var merged: [Range<Int>] = []
        for range in removals.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, last.upperBound >= range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        var result = Data()
        var copied = 0
        for range in merged {
            result.append(contentsOf: bytes[copied..<range.lowerBound])
            copied = range.upperBound
        }
        result.append(contentsOf: bytes[copied...])
        return result
    }

    private mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func string() throws -> String {
        guard index < bytes.count, bytes[index] == 34 else { throw CocoaError(.fileReadCorruptFile) }
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 92 { index += 1 }
            else if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private mutating func value(path: [String], depth: Int) throws {
        guard depth < 128 else { throw CocoaError(.fileReadCorruptFile) }
        whitespace()
        guard index < bytes.count else { throw CocoaError(.fileReadCorruptFile) }
        switch bytes[index] {
        case 123:
            index += 1
            whitespace()
            if bytes[index] == 125 { index += 1; return }
            var previousComma: Int?
            while true {
                let start = index
                let key = try string()
                whitespace()
                guard bytes[index] == 58 else { throw CocoaError(.fileReadCorruptFile) }
                index += 1
                try value(path: path + [key], depth: depth + 1)
                let end = index
                whitespace()
                let followedByComma = bytes[index] == 44
                if path.count == 2, path[1] == "endpoint", key == "hostCommand" {
                    removals.append(followedByComma ? start..<(index + 1) : (previousComma ?? start)..<end)
                }
                if followedByComma {
                    previousComma = index
                    index += 1
                    whitespace()
                } else {
                    guard bytes[index] == 125 else { throw CocoaError(.fileReadCorruptFile) }
                    index += 1
                    return
                }
            }
        case 91:
            index += 1
            whitespace()
            if bytes[index] == 93 { index += 1; return }
            while true {
                try value(path: path + ["[]"], depth: depth + 1)
                whitespace()
                if bytes[index] == 93 { index += 1; return }
                guard bytes[index] == 44 else { throw CocoaError(.fileReadCorruptFile) }
                index += 1
            }
        case 34:
            _ = try string()
        default:
            // JSONSerialization validated numbers, booleans and null already.
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
        }
    }
}

struct MacTerminalKeyError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "This iPhone could not use its Mac Terminal key (Keychain status \(status))."
    }
}
