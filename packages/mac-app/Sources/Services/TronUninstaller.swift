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

    @discardableResult
    static func unregisterAndClean(
        setup: EnvironmentSetup,
        options: Options = .preserveUserData
    ) async -> LaunchAgentOutcome {
        guard setup.canManageLaunchAgent else {
            return .launchdRefused(
                message: "This Xcode Debug wrapper is in companion mode and cannot uninstall the production Tron Server."
            )
        }
        let outcome = await setup.launchAgentManager.unload(label: setup.launchAgentLabel)
        guard outcome.isSuccessfulUninstall else {
            return outcome
        }

        cleanLocalState(setup: setup, options: options)
        return outcome
    }

    static func cleanLocalState(setup: EnvironmentSetup, options: Options) {
        let fm = FileManager.default
        for path in runtimeCleanupPaths(setup: setup) {
            try? fm.removeItem(at: path)
        }
        if options.resetSettings {
            try? fm.removeItem(at: setup.settingsPath)
        }
        if options.resetCredentials {
            try? fm.removeItem(at: setup.bearerTokenPath)
        }
    }

    static func runtimeCleanupPaths(setup: EnvironmentSetup) -> [URL] {
        let runDir = setup.onboardedMarkerPath.deletingLastPathComponent()
        return [
            setup.onboardedMarkerPath,
            runDir.appendingPathComponent("updater-state.json", isDirectory: false),
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
