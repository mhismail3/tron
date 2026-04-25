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

    /// Minimum height this step needs inside the fixed wizard canvas.
    /// `WizardShell` keeps the actual window at `WizardLayout.height`
    /// (the tallest step's height) so horizontal page transitions always
    /// run inside one stable viewport.
    ///
    /// Heights are deliberately collapsed into bands rather than tuned
    /// per-step: the three lightweight "gate" steps (welcome / tailscale
    /// / existingInstall) share a single lower-height band, while the
    /// fixed shell height is set to the tallest permissions page.
    var preferredHeight: CGFloat {
        switch self {
        case .welcome: return 360
        case .tailscale: return 360
        case .existingInstall: return 360
        case .permissions: return 480
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

/// One Settings round-trip initiated by a Permissions-step gear button.
/// App activation alone is too broad: System Settings focus changes can
/// activate the wrapper even when the user only navigated inside Settings.
struct PermissionSettingsReturn: Equatable, Sendable {
    var permission: Permission
    var statusBeforeOpen: PermissionStatus
}

enum PermissionSettingsReturnAction: Equatable, Sendable {
    case recheckOnly
    case restartAndRecheck
}

enum PermissionSettingsReturnPolicy {
    static func action(for pendingReturn: PermissionSettingsReturn?) -> PermissionSettingsReturnAction {
        guard let pendingReturn else {
            return .recheckOnly
        }

        switch pendingReturn.statusBeforeOpen {
        case .granted:
            return .recheckOnly
        case .denied, .notDetermined, .probeUnavailable:
            return .restartAndRecheck
        }
    }
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
    /// Copies the server binary, writes bundle metadata/resources, strips
    /// quarantine, and signs the app bundle before launchd ever starts it.
    case copyBinary
    case writePlist
    case loadAgent
    case awaitPing
}

/// Pure-value description of what the install step plans to do. The
/// View applies the plan via `LaunchAgentManaging`.
struct InstallPlan: Equatable, Sendable {
    var sourceBinary: URL
    var iconSource: URL? = nil
    var targetBundle: URL
    var targetBinary: URL
    var plistPath: URL
    var plistContents: String
    var requiresLoad: Bool
}
