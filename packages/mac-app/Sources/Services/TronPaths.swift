import Foundation

/// Single source of truth for filesystem paths the wrapper interacts
/// with. Mirrors `packages/agent/src/core/foundation/paths.rs` exports
/// for user data and the macOS bundle layout for app-owned artifacts.
enum TronPaths {
    private enum HomeComponent {
        static let internalDir = "internal"
        static let profilesDir = "profiles"
        static let userProfileDir = "user"
        static let runDir = "run"
        static let databaseDir = "database"
        static let authFile = "auth.json"
        static let profileFile = "profile.toml"
    }

    static let tronDataDirEnv = "TRON_DATA_DIR"
    static let tronHomeNameEnv = "TRON_HOME_NAME"
    static let isolatedInstallModeEnv = "TRON_MAC_INSTALL_MODE"
    static let isolatedInstallModeValue = "isolated"
    static let productionLaunchAgentLabel = "com.tron.server"
    static let isolatedLaunchAgentLabel = "com.tron.server.dev"
    static let productionServerPort = 9847
    static let isolatedServerPort = 9848

    static let homeDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
    }()

    static let tronHome: URL = {
        tronHome(environment: ProcessInfo.processInfo.environment)
    }()

    static func tronHome(environment: [String: String]) -> URL {
        if let override = environment[tronDataDirEnv], !override.isEmpty {
            precondition(override.hasPrefix("/"), "\(tronDataDirEnv) must be an absolute path")
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let homeName = environment[tronHomeNameEnv], !homeName.isEmpty {
            precondition(validHomeName(homeName), "\(tronHomeNameEnv) must be a single home-relative directory name")
            return homeDirectory.appendingPathComponent(homeName, isDirectory: true)
        }
        if isIsolatedInstallMode(environment: environment) {
            return homeDirectory.appendingPathComponent(".tron-dev", isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".tron", isDirectory: true)
    }

    static var internalDir: URL { tronHome.appendingPathComponent(HomeComponent.internalDir, isDirectory: true) }
    static var profilesDir: URL { tronHome.appendingPathComponent(HomeComponent.profilesDir, isDirectory: true) }
    static var userProfileDir: URL { profilesDir.appendingPathComponent(HomeComponent.userProfileDir, isDirectory: true) }
    static var runDir: URL { internalDir.appendingPathComponent(HomeComponent.runDir, isDirectory: true) }
    static var databaseLockPath: URL {
        internalDir
            .appendingPathComponent(HomeComponent.databaseDir, isDirectory: true)
            .appendingPathComponent("log.db.lock", isDirectory: false)
    }

    static let releaseApplicationURL = URL(fileURLWithPath: "/Applications/Tron.app", isDirectory: true)

    static var applicationBundle: URL { Bundle.main.bundleURL }
    static var loginItemsDir: URL {
        applicationBundle
            .appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
    }
    static var serverHelperBundle: URL {
        loginItemsDir.appendingPathComponent("\(agentBundleName).app", isDirectory: true)
    }
    static var serverHelperBinary: URL {
        serverHelperBundle
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("tron", isDirectory: false)
    }

    static var bearerTokenPath: URL {
        profilesDir.appendingPathComponent(HomeComponent.authFile, isDirectory: false)
    }

    static var onboardedMarkerPath: URL {
        runDir.appendingPathComponent(".onboarded", isDirectory: false)
    }

    static var updaterStatePath: URL {
        runDir.appendingPathComponent("updater-state.json", isDirectory: false)
    }

    static var macAppVersionMarkerPath: URL {
        runDir.appendingPathComponent("mac-app-version.json", isDirectory: false)
    }

    static var authLockPath: URL {
        runDir.appendingPathComponent("auth.lock", isDirectory: false)
    }

    static var macWrapperLockPath: URL {
        runDir.appendingPathComponent(macWrapperLockFileName(bundleIdentifier: Bundle.main.bundleIdentifier), isDirectory: false)
    }

    static var settingsPath: URL {
        userProfileDir.appendingPathComponent(HomeComponent.profileFile, isDirectory: false)
    }

    static var launchAgentPlistPath: URL {
        applicationBundle
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist", isDirectory: false)
    }

    static var serverHelperBundleProgram: String {
        serverHelperBundleProgram(environment: ProcessInfo.processInfo.environment)
    }

    static func serverHelperBundleProgram(environment: [String: String]) -> String {
        "Contents/Library/LoginItems/\(agentBundleName(environment: environment)).app/Contents/MacOS/tron"
    }

    static var autoDeployPlistPath: URL {
        homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.tron.auto-deploy.plist", isDirectory: false)
    }

    static var launchAgentLabel: String {
        launchAgentLabel(environment: ProcessInfo.processInfo.environment)
    }

    static func launchAgentLabel(environment: [String: String]) -> String {
        isIsolatedInstallMode(environment: environment) ? isolatedLaunchAgentLabel : productionLaunchAgentLabel
    }

    static var defaultServerPort: Int {
        defaultServerPort(environment: ProcessInfo.processInfo.environment)
    }

    static func defaultServerPort(environment: [String: String]) -> Int {
        isIsolatedInstallMode(environment: environment) ? isolatedServerPort : productionServerPort
    }

    static var launchAgentEnvironmentVariables: [String: String] {
        launchAgentEnvironmentVariables(environment: ProcessInfo.processInfo.environment)
    }

    static func launchAgentEnvironmentVariables(environment: [String: String]) -> [String: String] {
        if isIsolatedInstallMode(environment: environment) {
            return ["RUST_LOG": "info", tronHomeNameEnv: ".tron-dev"]
        }
        return ["RUST_LOG": "info"]
    }

    static var canManageLaunchAgent: Bool {
        MacRuntimeVariant.detect().canManageLaunchAgent(isIsolatedInstallMode: isIsolatedInstallMode())
    }
    /// Bundle identifier for the active embedded server helper, not the
    /// menu-bar wrapper. It intentionally matches the active LaunchAgent label
    /// so launchd diagnostics and helper signature checks name the same
    /// service in both production and isolated install-test modes.
    static var bundleID: String {
        bundleID(environment: ProcessInfo.processInfo.environment)
    }

    static func bundleID(environment: [String: String]) -> String {
        launchAgentLabel(environment: environment)
    }
    /// User-facing display name for the agent in System Settings, Activity
    /// Monitor, and the Dock (if it ever surfaced). Kept separate from the
    /// wrapper's "Tron" name so the three permission panes never show two
    /// entries titled "Tron".
    static var agentDisplayName: String {
        agentDisplayName(environment: ProcessInfo.processInfo.environment)
    }

    static func agentDisplayName(environment: [String: String]) -> String {
        agentBundleName(environment: environment)
    }
    static var agentBundleName: String {
        agentBundleName(environment: ProcessInfo.processInfo.environment)
    }

    static func agentBundleName(environment: [String: String]) -> String {
        isIsolatedInstallMode(environment: environment) ? "Tron Server Dev" : "Tron Server"
    }
    /// Wrapper bundle identifiers that may own the SMAppService
    /// registration. launchd uses the active parent bundle as the
    /// responsible app for some TCC services, so the LaunchAgent plist
    /// associates the service with wrapper variants instead of the helper.
    static var associatedWrapperBundleIDs: [String] {
        associatedWrapperBundleIDs(environment: ProcessInfo.processInfo.environment)
    }

    static func associatedWrapperBundleIDs(
        environment: [String: String]
    ) -> [String] {
        let release = MacRuntimeVariant.releaseBundleIdentifier
        let debug = MacRuntimeVariant.debugBundleIdentifier
        if isIsolatedInstallMode(environment: environment) {
            return [debug, release]
        }
        return [release, debug]
    }

    static func isIsolatedInstallMode(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[isolatedInstallModeEnv] == isolatedInstallModeValue
    }

    static func macWrapperLockFileName(bundleIdentifier: String?) -> String {
        let rawIdentifier = bundleIdentifier?.isEmpty == false ? bundleIdentifier! : "unknown"
        let safeIdentifier = rawIdentifier.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == UnicodeScalar(".")
                || scalar == UnicodeScalar("-") {
                return Character(scalar)
            }
            return "-"
        }
        return ".mac-wrapper.\(String(safeIdentifier)).lock"
    }

    private static func validHomeName(_ value: String) -> Bool {
        value != "." && value != ".." && !value.contains("/")
    }
}
