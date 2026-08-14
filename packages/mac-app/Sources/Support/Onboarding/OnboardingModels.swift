import Foundation

/// Steps in the first-run wizard. `allCases` is the canonical flow;
/// tests in `WizardStepOrderingTests` pin it to prevent silent reorderings.
enum WizardStep: String, CaseIterable, Identifiable, Codable, Sendable {
    case welcome
    case tailscale
    case install
    case permissions
    case connectIPhone
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
        case .install: return "Install Tron"
        case .connectIPhone: return "Connect your iPhone"
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
        case .install: return .symbol("arrow.down.circle.fill")
        case .connectIPhone: return .symbol("qrcode")
        case .done: return .symbol("checkmark.seal.fill")
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

/// Permission category the wizard probes during the Permissions step.
/// The Mac wrapper only preflights broad local file access; visual
/// inspection and click/type control are no longer startup requirements.
enum Permission: String, CaseIterable, Sendable {
    case fullDiskAccess

    var systemSettingsURL: URL {
        switch self {
        case .fullDiskAccess:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        }
    }
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

/// Current Login Item registration observed by onboarding.
enum GatewayInstallStatus: Equatable, Sendable {
    case none
    case requiresApproval
    case partial(reason: String)
    case registered(version: String?)
}

/// Canonical `system.info` projection needed by the wrapper after the decoder
/// validates the complete required response shape.
struct GatewayHealthInfo: Equatable, Sendable {
    var version: String
}

/// Pairing payload shared with the iOS app via the
/// `tron://pair?host=...&port=...&code=...&label=...` URL.
/// The `label` query item is the user-facing Mac name on iOS.
struct PairingPayload: Equatable, Sendable, Hashable {
    var host: String
    var port: Int
    var code: String
    var label: String?
}
