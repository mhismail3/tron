import Foundation

/// Steps in the first-run wizard. `allCases` is the canonical flow;
/// tests in `WizardStepTests` pin it to prevent silent reorderings.
enum WizardStep: String, CaseIterable, Identifiable, Codable, Sendable {
    case welcome
    case tailscale
    case install
    case permissions
    case iosBeta
    case pairingInfo
    case done

    var id: String { rawValue }

    /// Title rendered in the wizard's shared header row. Each step's
    /// own body no longer renders a title — it's hoisted into
    /// `WizardShell` so the icon, title, and progress pill all sit
    /// on the same baseline.
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

    /// Glyph rendered to the left of `displayTitle` in the shell's
    /// header row. The Welcome step uses the brand asset; every other
    /// step uses an SF Symbol so a single rendering path styles them
    /// uniformly with `Color.tronEmerald`.
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

    /// Minimum height this step needs inside the fixed wizard canvas.
    /// `WizardShell` keeps the actual window at `WizardLayout.height`
    /// (the tallest step's height) so horizontal page transitions always
    /// run inside one stable viewport.
    ///
    /// Heights are deliberately collapsed into bands rather than tuned
    /// per-step: the lightweight opening steps share a single lower-height
    /// band, while the fixed shell height is set to the tallest
    /// permissions page.
    var preferredHeight: CGFloat {
        switch self {
        case .welcome: return 360
        case .tailscale: return 360
        case .permissions: return 480
        case .iosBeta: return 420
        case .install: return 440
        case .pairingInfo: return 420
        case .done: return 320
        }
    }
}

/// Discriminated source for the icon rendered in `WizardShell`'s
/// header row. Asset cases are rendered as `Image(_:)` with the
/// template rendering mode (so `foregroundStyle` tints them); symbol
/// cases use `Image(systemName:)` directly.
enum HeaderIcon: Equatable, Sendable {
    case asset(String)
    case symbol(String)
}

/// Permission categories the wizard probes during the Permissions step.
///
/// The Rust agent's screenshot path calls `screencapture(1)`, which
/// requires Screen Recording. The primitive wrapper does not request a
/// notification permission because the push/inbox product plane is gone.
enum Permission: String, CaseIterable, Sendable {
    case fullDiskAccess
    case screenRecording
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

/// Existing server registration detection result. This deliberately
/// models the Login Item registration, not whether the server is
/// currently reachable. The Install step must still start/kickstart
/// and ping the helper before it can advance.
enum ExistingInstallStatus: Equatable, Sendable {
    case none
    case requiresApproval
    case partial(reason: String)
    case registered(version: String?)
}

/// Subset of `system.getInfo` the wrapper needs. Decoded from the WS engine protocol
/// response by `ServerPing`.
struct ServerInfo: Equatable, Sendable {
    var version: String
    var port: Int
    var tailscaleIp: String?
    var paired: Bool
}

/// Pairing payload shared with the iOS app via the
/// `tron://pair?host=...&port=...&token=...&label=...` URL.
/// The `label` query item is the user-facing server name on iOS.
struct PairingPayload: Equatable, Sendable, Hashable {
    var host: String
    var port: Int
    var token: String
    var label: String?
}

/// Discrete steps in the install pipeline. Each is
/// tested separately in `InstallPlannerTests`.
enum InstallPipelineStage: String, Equatable, Sendable, CaseIterable {
    /// Confirms this is the release app in `/Applications`.
    case validateApplication
    /// Confirms the embedded helper app, plist, and signature are intact.
    case validateHelper
    /// Registers the bundled LaunchAgent through `SMAppService`.
    case registerAgent
    case awaitPing
}

/// Pure-value description of what the install step plans to do. The
/// View applies the plan via `SMAppService` through `LaunchAgentManaging`.
struct InstallPlan: Equatable, Sendable {
    var plistPath: URL
    var helperBundle: URL
    var helperBinary: URL
}
