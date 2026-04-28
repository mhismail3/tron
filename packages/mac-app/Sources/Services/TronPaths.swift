import Foundation

/// Single source of truth for filesystem paths the wrapper interacts
/// with. Mirrors `packages/agent/src/core/foundation/paths.rs` exports
/// for user data and the macOS bundle layout for app-owned artifacts.
enum TronPaths {
    static let homeDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
    }()

    static let tronHome: URL = {
        if let override = ProcessInfo.processInfo.environment["TRON_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".tron", isDirectory: true)
    }()

    static var systemDir: URL { tronHome.appendingPathComponent("system", isDirectory: true) }
    static var runDir: URL { systemDir.appendingPathComponent("run", isDirectory: true) }
    static var databaseLockPath: URL {
        systemDir
            .appendingPathComponent("database", isDirectory: true)
            .appendingPathComponent("log.db.lock", isDirectory: false)
    }

    static let releaseApplicationURL = URL(fileURLWithPath: "/Applications/Tron.app", isDirectory: true)

    static var applicationBundle: URL { Bundle.main.bundleURL }
    static var loginItemsDir: URL {
        applicationBundle
            .appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
    }
    static var serverHelperBundle: URL {
        loginItemsDir.appendingPathComponent("\(agentDisplayName).app", isDirectory: true)
    }
    static var serverHelperBinary: URL {
        serverHelperBundle
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("tron", isDirectory: false)
    }

    static var bearerTokenPath: URL {
        systemDir.appendingPathComponent("auth.json", isDirectory: false)
    }

    static var onboardedMarkerPath: URL {
        runDir.appendingPathComponent(".onboarded", isDirectory: false)
    }

    static var updaterStatePath: URL {
        runDir.appendingPathComponent("updater-state.json", isDirectory: false)
    }

    static var authLockPath: URL {
        runDir.appendingPathComponent("auth.lock", isDirectory: false)
    }

    static var macWrapperLockPath: URL {
        runDir.appendingPathComponent(".mac-wrapper.lock", isDirectory: false)
    }

    static var settingsPath: URL {
        systemDir.appendingPathComponent("settings.json", isDirectory: false)
    }

    static var transcriptionDir: URL {
        systemDir.appendingPathComponent("transcription", isDirectory: true)
    }

    static var transcriptionResourceDir: URL {
        (Bundle.main.resourceURL ?? applicationBundle.appendingPathComponent("Contents/Resources", isDirectory: true))
            .appendingPathComponent("Transcription", isDirectory: true)
    }

    static var launchAgentPlistPath: URL {
        applicationBundle
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist", isDirectory: false)
    }

    static var autoDeployPlistPath: URL {
        homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.tron.auto-deploy.plist", isDirectory: false)
    }

    static let launchAgentLabel = "com.tron.server"
    static let defaultServerPort = 9847
    /// Bundle identifier for the embedded server helper
    /// (`Contents/Library/LoginItems/Tron Server.app`), not the
    /// menu-bar wrapper. Intentionally matches `launchAgentLabel` so
    /// launchd diagnostics and helper signature checks name the same
    /// service. The menu-bar wrapper's own bundle id lives in its
    /// Info.plist (`com.tron.mac` / `com.tron.mac.dev`).
    static let bundleID = "com.tron.server"
    /// User-facing display name for the agent in System Settings, Activity
    /// Monitor, and the Dock (if it ever surfaced). Kept separate from the
    /// wrapper's "Tron" name so the three permission panes never show two
    /// entries titled "Tron".
    static let agentDisplayName = "Tron Server"
    /// Wrapper bundle identifiers that may own the SMAppService
    /// registration. launchd uses the active parent bundle as the
    /// responsible app for some TCC services, so the LaunchAgent plist
    /// associates the service with wrapper variants instead of the helper.
    static let associatedWrapperBundleIDs = [
        MacRuntimeVariant.releaseBundleIdentifier,
        MacRuntimeVariant.debugBundleIdentifier,
    ]
}
