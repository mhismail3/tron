import Foundation

/// The wrapper has four supported operating modes:
/// - Debug/Xcode (`com.tron.mac.dev`) companion mode, allowed from DerivedData and
///   meant to observe/control UI while the installed app owns production server registration.
/// - Debug/Xcode isolated install mode, opt-in via `TRON_MAC_INSTALL_MODE=isolated`
///   for testing first-run/reinstall flows against a separate label, port, and data tree.
/// - Installed release (`com.tron.mac` at `/Applications/Tron.app`), used by both
///   a real DMG install and a local Release build copied into Applications.
/// - Unsupported/misplaced release builds, which must fail loudly before registration.
enum MacRuntimeVariant: Equatable, Sendable {
    case xcodeDebug(bundlePath: String)
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
            return .xcodeDebug(bundlePath: path)
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

    var precedence: Int {
        switch self {
        case .xcodeDebug:
            return 2
        case .installedRelease:
            return 2
        case .misplacedRelease, .unsupported:
            return 0
        }
    }

    var locationProblem: String? {
        switch self {
        case .xcodeDebug, .installedRelease:
            return nil
        case .misplacedRelease:
            return "Move Tron.app to /Applications before installing the server."
        case .unsupported(let bundleIdentifier):
            let identifier = bundleIdentifier ?? "missing bundle identifier"
            return "Unsupported Tron wrapper build (\(identifier)). Use Xcode Debug or /Applications/Tron.app."
        }
    }

    static func precedence(forParentBundleIdentifier bundleIdentifier: String?) -> Int {
        switch bundleIdentifier {
        case debugBundleIdentifier, releaseBundleIdentifier:
            return 2
        case .some:
            return 1
        case nil:
            return 0
        }
    }

    func canManageLaunchAgent(isIsolatedInstallMode: Bool) -> Bool {
        switch self {
        case .installedRelease:
            return true
        case .xcodeDebug:
            return isIsolatedInstallMode
        case .misplacedRelease, .unsupported:
            return false
        }
    }
}
