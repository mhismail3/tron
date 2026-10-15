import Foundation

/// Paved-path uninstall for the Mac wrapper. This unregisters the
/// SMAppService Login Item and removes only local runtime state; durable
/// user data stays unless the caller explicitly resets it.
enum TronUninstaller {
    struct Options: Equatable, Sendable {
        var resetSettings: Bool = false
        var resetCredentials: Bool = false

        static let preserveUserData = Options()
    }

    struct Result {
        let outcome: LaunchAgentOutcome
        /// Local state the uninstall was asked to remove but could not. A
        /// requested reset that left a file behind must not read as complete.
        let remainingPaths: [URL]
    }

    @discardableResult
    static func unregisterAndClean(
        setup: EnvironmentSetup,
        options: Options = .preserveUserData
    ) async -> Result {
        guard setup.canManageLaunchAgent else {
            return Result(outcome: .launchdRefused(
                message: "This Xcode Debug wrapper is in companion mode and cannot uninstall the production Tron Agent."
            ), remainingPaths: [])
        }
        // The old authenticated wrapper must finish native retirement before
        // changing either service; Gateway departure alone is not capture Stop.
        do { try await setup.unregisterNativeHost() }
        catch { return Result(outcome: .launchdRefused(message: "Tron's native helper could not be retired. Gateway registration and local state were preserved."), remainingPaths: []) }

        let outcome = await setup.launchAgentManager.unload(label: setup.launchAgentLabel)
        guard outcome.isSuccessfulUninstall else {
            return Result(outcome: outcome, remainingPaths: [])
        }

        // Stable uninstall owns only the stable services. Developer-owned
        // Debug registration, data, credentials, and sessions are untouched.
        return Result(outcome: outcome, remainingPaths: removeLocalState(at: localStatePaths(setup: setup, options: options)))
    }

    static func localStatePaths(setup: EnvironmentSetup, options: Options) -> [URL] {
        var paths = runtimeCleanupPaths(setup: setup)
        if options.resetSettings { paths.append(setup.networkCachePath) }
        if options.resetCredentials { paths.append(setup.bearerTokenPath) }
        return paths
    }

    /// Removes each path and returns those still present. Only an already
    /// absent file counts as removed; every other failure is logged and kept.
    static func removeLocalState(at paths: [URL], fileManager: FileManager = .default) -> [URL] {
        paths.filter { path in
            do {
                try fileManager.removeItem(at: path)
                return false
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                return false
            } catch {
                TronLog.shared.record(
                    .warning, event: "launch-agent.uninstall-cleanup", source: "launch-agent",
                    message: "Could not remove \(path.path): \(error.localizedDescription)", outcome: "failed"
                )
                return true
            }
        }
    }

    static func runtimeCleanupPaths(setup: EnvironmentSetup) -> [URL] {
        let runDir = setup.onboardedMarkerPath.deletingLastPathComponent()
        return [
            setup.onboardedMarkerPath,
            runDir.appendingPathComponent("auth.lock", isDirectory: false),
            setup.wrapperLockPath,
        ]
    }
}

private extension LaunchAgentOutcome {
    var isSuccessfulUninstall: Bool {
        switch self {
        case .ok, .alreadyLoaded:
            return true
        case .requiresApproval, .launchdRefused, .binaryMissing, .unknown:
            return false
        }
    }
}
