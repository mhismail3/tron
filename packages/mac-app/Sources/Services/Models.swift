import Foundation

/// Steps in the first-run wizard. Order is canonical; tests in
/// `WizardStepTests` pin `OnboardingStep.allCases` to prevent silent
/// reorderings.
enum WizardStep: String, CaseIterable, Identifiable, Codable, Sendable {
    case welcome
    case tailscale
    case existingInstall
    case permissions
    case install
    case pairingInfo
    case done

    var id: String { rawValue }

    /// Title rendered in the wizard's shared header row. Each step's
    /// own body no longer renders a title — it's hoisted into
    /// `WizardShell` so the back chevron, logo, title, and progress
    /// pill all sit on the same baseline.
    var displayTitle: String {
        switch self {
        case .welcome: return "Welcome to Tron"
        case .tailscale: return "Tailscale"
        case .existingInstall: return "Existing install"
        case .permissions: return "Permissions"
        case .install: return "Install Tron"
        case .pairingInfo: return "Pair your iPhone"
        case .done: return "You're all set"
        }
    }
}

/// Permission categories the wizard probes during the Permissions step.
enum Permission: String, CaseIterable, Sendable {
    case fullDiskAccess
    case notifications
    case accessibility
}

/// Per-permission grant state. Mirrors TCC categories.
enum PermissionStatus: String, Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    case probeUnavailable
}

/// Tailscale state on the host. Used by the Tailscale prerequisite step.
enum TailscaleStatus: Equatable, Sendable {
    case notInstalled
    case installedNotSignedIn
    case signedIn(ipv4: String)

    var isReady: Bool {
        if case .signedIn = self { return true }
        return false
    }

    var displayIP: String? {
        if case .signedIn(let ip) = self { return ip }
        return nil
    }
}

/// Existing-install detection result. Drives whether the wizard skips
/// the Install step.
enum ExistingInstallStatus: Equatable, Sendable {
    case none
    case partial(reason: String)
    case installed(version: String?)

    var hasInstall: Bool {
        switch self {
        case .none: return false
        case .partial, .installed: return true
        }
    }
}

/// Subset of `system.getInfo` the wrapper needs. Decoded from the WS RPC
/// response by `ServerPing`.
struct ServerInfo: Equatable, Sendable {
    var version: String
    var port: Int
    var tailscaleIp: String?
    var paired: Bool
}

/// Pairing payload shared with the iOS app via the
/// `tron://pair?host=...&port=...&token=...&label=...` URL.
struct PairingPayload: Equatable, Sendable, Hashable {
    var host: String
    var port: Int
    var token: String
    var label: String?
}

/// Discrete steps in the install pipeline (wizard step 5). Each is
/// tested separately in `InstallPlannerTests`.
enum InstallPipelineStage: String, Equatable, Sendable, CaseIterable {
    case copyBinary
    case writePlist
    case loadAgent
    case awaitPing
}

/// Pure-value description of what the install step plans to do. The
/// View applies the plan via `LaunchAgentManaging`.
struct InstallPlan: Equatable, Sendable {
    var sourceBinary: URL
    var targetBundle: URL
    var targetBinary: URL
    var plistPath: URL
    var plistContents: String
    var requiresLoad: Bool
}
