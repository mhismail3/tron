import Foundation

/// The one authority for wrapper startup routing. Lifecycle owners consume
/// this value rather than independently deriving bundle, command, and marker
/// state.
enum MacStartupMode: Equatable, Sendable {
    case testHost
    case command(MacCommandLineMode)
    case debugReadOnly
    case wizard
    case onboarded
    case misplacedRelease
    case unsupported

    static func resolve(
        variant: MacRuntimeVariant,
        onboarded: Bool,
        command: MacCommandLineMode,
        underTests: Bool
    ) -> MacStartupMode {
        if underTests { return .testHost }
        if command.isCommand { return .command(command) }
        switch variant {
        case .xcodeDebug: return .debugReadOnly
        case .installedRelease: return onboarded ? .onboarded : .wizard
        case .misplacedRelease: return .misplacedRelease
        case .unsupported: return .unsupported
        }
    }

    var isReadOnlyDebug: Bool {
        if case .debugReadOnly = self { return true }
        return false
    }

    var isManagedRelease: Bool {
        if case .onboarded = self { return true }
        return false
    }
}

/// The wrapper has three supported operating modes:
/// - Debug/Xcode (`com.tron.mac.dev`) is a companion and never manages a Gateway.
/// - Installed Release (`com.tron.mac` at `/Applications/Tron.app`) owns Stable.
/// - Unsupported/misplaced Release builds fail before registration.
enum MacRuntimeVariant: Equatable, Sendable {
    case xcodeDebug
    case installedRelease
    case misplacedRelease(actualPath: String)
    case unsupported(bundleIdentifier: String?)

    static let releaseBundleIdentifier = "com.tron.mac"
    static let debugBundleIdentifier = "com.tron.mac.dev"

    static func detect(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> MacRuntimeVariant {
        let path = bundleURL.standardizedFileURL.path
        switch bundleIdentifier {
        case debugBundleIdentifier:
            return .xcodeDebug
        case releaseBundleIdentifier:
            if path == TronPaths.releaseApplicationURL.standardizedFileURL.path {
                return .installedRelease
            }
            return .misplacedRelease(actualPath: path)
        default:
            return .unsupported(bundleIdentifier: bundleIdentifier)
        }
    }

    var expectedParentBundleIdentifier: String? {
        switch self {
        case .xcodeDebug:
            return Self.debugBundleIdentifier
        case .installedRelease:
            return Self.releaseBundleIdentifier
        case .misplacedRelease, .unsupported:
            return nil
        }
    }

    var locationProblem: String? {
        switch self {
        case .xcodeDebug, .installedRelease:
            return nil
        case .misplacedRelease:
            return "Move Tron.app to /Applications before installing Tron."
        case .unsupported(let bundleIdentifier):
            let identifier = bundleIdentifier ?? "missing bundle identifier"
            return "Unsupported Tron wrapper build (\(identifier)). Use Xcode Debug or /Applications/Tron.app."
        }
    }

    func canTakeOverRegistration(ownedBy bundleIdentifier: String) -> Bool {
        self == .installedRelease && bundleIdentifier != Self.releaseBundleIdentifier
    }

    func canManageLaunchAgent(isIsolatedInstallMode: Bool) -> Bool {
        self == .installedRelease && !isIsolatedInstallMode
    }

    /// Release owns Stable only. Debug can observe Gateways but never manages
    /// registration or process lifecycle.
    func canManageLaunchAgent(
        profile: TronGatewayProfile = .stable,
        isIsolatedInstallMode: Bool
    ) -> Bool {
        switch self {
        case .installedRelease:
            return profile == .stable && !isIsolatedInstallMode
        case .xcodeDebug, .misplacedRelease, .unsupported:
            return false
        }
    }
}
