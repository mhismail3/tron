import Foundation

/// Single source of truth for filesystem paths the wrapper interacts
/// with. Mirrors `scripts/tron-lib.sh` constants and
/// `packages/agent/src/core/foundation/paths.rs` exports - if any of
/// these drift, tests in `Tests/Services/TronPathsTests.swift` should
/// catch the mismatch.
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
    static var deploymentDir: URL { systemDir.appendingPathComponent("deployment", isDirectory: true) }

    static var installedBundle: URL { systemDir.appendingPathComponent("Tron.app", isDirectory: true) }
    static var installedBinary: URL {
        installedBundle
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("tron", isDirectory: false)
    }

    static var devBundle: URL { deploymentDir.appendingPathComponent("Tron-Dev.app", isDirectory: true) }
    static var devBinary: URL {
        devBundle
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("tron", isDirectory: false)
    }

    static var bearerTokenPath: URL {
        systemDir.appendingPathComponent("auth-token.json", isDirectory: false)
    }

    static var onboardedMarkerPath: URL {
        systemDir.appendingPathComponent(".onboarded", isDirectory: false)
    }

    static var settingsPath: URL {
        systemDir.appendingPathComponent("settings.json", isDirectory: false)
    }

    static var launchAgentPlistPath: URL {
        homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist", isDirectory: false)
    }

    static var autoDeployPlistPath: URL {
        homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.tron.auto-deploy.plist", isDirectory: false)
    }

    static let launchAgentLabel = "com.tron.server"
    static let defaultServerPort = 9847
    static let bundleID = "com.tron.agent"
}
