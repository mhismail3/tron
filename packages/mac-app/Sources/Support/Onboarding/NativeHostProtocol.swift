import Foundation
import Security

/// Wrapper-only setup and service retirement. The separate capture listener
/// cannot request permissions or authorize service retirement.
@objc(NativeHostPermissionService)
protocol NativeHostPermissionService {
    func probePermissions(withReply reply: @escaping @Sendable ([String: String]) -> Void)
    func prepareForServiceRetirement(withReply reply: @escaping @Sendable (Bool) -> Void)
    func requestPermission(_ permission: String, requestID: String,
                           withReply reply: @escaping @Sendable (String, String) -> Void)
}

enum NativeHostPermission: String, CaseIterable, Hashable, Sendable {
    case accessibility
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
    static let captureMachServiceName = "com.tron.mac.native-host.capture"
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
