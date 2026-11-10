import Foundation

enum WizardStep: String, CaseIterable, Identifiable, Codable, Sendable {
    case welcome
    case tailscale
    case install
    case permissions
    case iosBeta
    case pairingInfo
    case done

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .welcome: return "Tron Installer"
        case .tailscale: return "Tailscale"
        case .permissions: return "Permissions"
        case .iosBeta: return "Install iOS Beta"
        case .install: return "Install Tron"
        case .pairingInfo: return "Pair your iPhone"
        case .done: return "You're all set"
        }
    }

    var headerIcon: HeaderIcon {
        switch self {
        case .welcome: return .asset("TronLogo")
        case .tailscale: return .symbol("network")
        case .permissions: return .symbol("lock.shield.fill")
        case .iosBeta: return .symbol("iphone")
        case .install: return .symbol("arrow.down.circle.fill")
        case .pairingInfo: return .symbol("qrcode")
        case .done: return .symbol("checkmark.seal.fill")
        }
    }

}

enum HeaderIcon: Equatable, Sendable {
    case asset(String)
    case symbol(String)
}

enum Permission: String, CaseIterable, Sendable {
    case fullDiskAccess
    case accessibility
    case screenRecording

    static func coreSetupSatisfied(by statuses: [Permission: PermissionStatus]) -> Bool {
        statuses[.fullDiskAccess] == .granted
    }

    var systemSettingsURL: URL {
        switch self {
        case .fullDiskAccess:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}

enum PermissionStatus: String, Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    case probeUnavailable
}

enum TailscaleStatus: Equatable, Sendable {
    case notInstalled
    case installedNotSignedIn
    case signedIn(address: String)

    var isReady: Bool {
        if case .signedIn = self { return true }
        return false
    }

    var displayIP: String? {
        if case .signedIn(let ip) = self { return ip }
        return nil
    }
}

enum ExistingInstallStatus: Equatable, Sendable {
    case none
    case requiresApproval
    case partial(reason: String)
    case registered(version: String?)
}

struct ServerPingInfo: Equatable, Sendable {
    var version: String
    var gatewayChannel: String
    var sourceRevision: String?
    var buildFingerprint: String?
    var runtimeEpoch: String?

    init(
        version: String,
        gatewayChannel: String,
        sourceRevision: String? = nil,
        buildFingerprint: String? = nil,
        runtimeEpoch: String? = nil
    ) {
        self.version = version
        self.gatewayChannel = gatewayChannel
        self.sourceRevision = sourceRevision
        self.buildFingerprint = buildFingerprint
        self.runtimeEpoch = runtimeEpoch
    }
}

struct PairingPayload: Equatable, Sendable, Hashable {
    var host: String
    var port: Int
    var code: String
    var label: String?
}

enum InstallPipelineStage: String, Equatable, Sendable, CaseIterable {
    case validateApplication
    case validateHelper
    case registerAgent
    case awaitPing
}
