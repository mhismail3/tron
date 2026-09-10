import Foundation
import Security

/// The only messages exposed by the bundled GUI permission host. Permission
/// requests are explicit user actions; probing never asks TCC to present UI.
@objc(NativeHostPermissionService)
protocol NativeHostPermissionService {
    func probePermissions(withReply reply: @escaping @Sendable ([String: String]) -> Void)
    func requestPermission(_ permission: String, requestID: String,
                           withReply reply: @escaping @Sendable (String, String) -> Void)
}

enum NativeHostPermission: String, CaseIterable, Hashable, Sendable {
    case accessibility
    case inputMonitoring
    case screenRecording
}

enum NativeHostPermissionStatus: String, Sendable {
    case granted
    case notDetermined
    case probeUnavailable
}

enum NativeHostTrust {
    static let bundleIdentifier = "com.tron.mac.native-host"
    static let relativeBundlePath = "Contents/Library/Native/Tron Native Host.app"
    static let machServiceName = "com.tron.mac.native-host"
    static let launchAgentPlistName = "com.tron.mac.native-host.plist"

    // Both sides enforce the requirement. The team and fixed identifiers bind
    // the peer to this product's signed composition; PID, model fields, and
    // a Mach service name are never treated as authentication.
    static var wrapperCodeSigningRequirement: String {
        get throws { try requirement(identifier: "com.tron.mac", team: Bundle.main.object(forInfoDictionaryKey: "TronSigningTeam") as? String) }
    }
    static var hostCodeSigningRequirement: String {
        get throws { try requirement(identifier: bundleIdentifier, team: Bundle.main.object(forInfoDictionaryKey: "TronSigningTeam") as? String) }
    }
    /// Pin messages to the actual signed bundled build, not another installed
    /// app with the same team/identifier serving the registered Mach name.
    static func pin(_ base: String, to bundle: URL) throws -> String {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(base as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let hash = (information as NSDictionary?)?[kSecCodeInfoUnique] as? Data, hash.count == 20 else {
            throw NativeHostTrustError.invalidIdentity
        }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return base + " and cdhash H\"" + hex + "\""
    }

    static func requirement(identifier: String, team: String?) throws -> String {
        guard let team, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              identifier == bundleIdentifier || identifier == "com.tron.mac" else { throw NativeHostTrustError.invalidIdentity }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }
}
enum NativeHostTrustError: Error { case invalidIdentity }

/// Host-main-queue owned receipts, not a permission cache. A replay returns the
/// original command result; callers still probe current TCC state afterward.
struct NativePermissionRequestReceipts {
    private var order: [UUID] = []
    private var receipts: [UUID: (permission: NativeHostPermission, status: String)] = [:]
    func cachedStatus(for permission: NativeHostPermission, id: UUID) -> String? {
        guard let receipt = receipts[id] else { return nil }
        return receipt.permission == permission ? receipt.status : NativeHostPermissionStatus.probeUnavailable.rawValue
    }
    mutating func record(_ status: String, for permission: NativeHostPermission, id: UUID) {
        guard receipts[id] == nil else { return }
        if order.count == 16 { receipts.removeValue(forKey: order.removeFirst()) }
        order.append(id)
        receipts[id] = (permission, status)
    }
}
