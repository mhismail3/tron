import Foundation

/// Steps in the first-run wizard. Order is canonical; tests in
/// `WizardStepTests` pin `OnboardingStep.allCases` to prevent silent
/// reorderings.
enum WizardStep: String, CaseIterable, Identifiable, Codable, Sendable {
    case welcome
    case tailscale
    case existingInstall
    case install
    case permissions
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
        case .existingInstall: return "Existing install"
        case .permissions: return "Permissions"
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
        case .existingInstall: return .symbol("magnifyingglass")
        case .permissions: return .symbol("lock.shield.fill")
        case .install: return .symbol("arrow.down.circle.fill")
        case .pairingInfo: return .symbol("qrcode")
        case .done: return .symbol("checkmark.seal.fill")
        }
    }

    /// Preferred height of the wizard canvas for this step. The shell
    /// reads this and animates the window frame between steps so dense
    /// steps (Permissions, Install, PairingInfo) get enough room for
    /// their cards without scrolling, and sparse steps (Welcome, Done,
    /// ExistingInstall) don't float in dead space. Width stays pinned
    /// at 480 for every step — only height varies.
    ///
    /// Heights are deliberately collapsed into bands rather than tuned
    /// per-step: the three lightweight "gate" steps (welcome / tailscale
    /// / existingInstall) share a single height so the user can walk
    /// through the opening of the wizard without the window resizing
    /// between each click. Resizes only happen when the next step
    /// genuinely needs more room (install → permissions) or
    /// substantially less (pairingInfo → done). `WizardShell` further
    /// no-ops the AppKit resize animation when the delta is < 1pt, so
    /// steps that share a band stay completely still during navigation.
    var preferredHeight: CGFloat {
        switch self {
        case .welcome: return 360
        case .tailscale: return 360
        case .existingInstall: return 360
        case .permissions: return 480
        case .install: return 400
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
/// `screenRecording` replaced `notifications` once we verified the Mac
/// wrapper never posts a local notification (all APNS-driven alerts
/// flow to the iOS companion app). The Rust agent's Computer-Use tool
/// calls `screencapture(1)` for every screenshot, which requires
/// Screen Recording — see
/// `packages/agent/src/tools/ui/computer_use/permissions.rs`.
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
