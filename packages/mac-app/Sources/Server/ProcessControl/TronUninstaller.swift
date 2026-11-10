import Foundation

enum TronUninstaller {
    struct Options: Equatable, Sendable {
        var resetSettings: Bool = false
        var resetCredentials: Bool = false

        static let preserveUserData = Options()
    }

    struct Result {
        let outcome: LaunchAgentOutcome
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
        do { try await setup.unregisterNativeHost() }
        catch { return Result(outcome: .launchdRefused(message: "Tron's native helper could not be retired. Gateway registration and local state were preserved."), remainingPaths: []) }

        let outcome = await setup.launchAgentManager.unload(label: setup.launchAgentLabel)
        guard outcome.isSuccessfulUninstall else {
            return Result(outcome: outcome, remainingPaths: [])
        }

        return Result(outcome: outcome, remainingPaths: removeLocalState(at: localStatePaths(setup: setup, options: options)))
    }

    static func localStatePaths(setup: EnvironmentSetup, options: Options) -> [URL] {
        var paths = runtimeCleanupPaths(setup: setup)
        if options.resetSettings { paths.append(setup.networkCachePath) }
        if options.resetCredentials { paths.append(setup.bearerTokenPath) }
        return paths
    }

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
