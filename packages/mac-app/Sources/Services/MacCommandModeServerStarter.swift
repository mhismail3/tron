import Foundation

enum MacCommandModeServerStartResult: Equatable, Sendable {
    case ok
    case invalidApplicationLocation(String)
    case invalidBundledHelper(String)
    case unmanagedWrapper
    case managedSkillSyncFailed(String)
    case launchAgentFailed(LaunchAgentOutcome)
    case unhealthy(ServerPingResult)
}

enum MacCommandModeServerStarter {
    static func start(setup: EnvironmentSetup) async -> MacCommandModeServerStartResult {
        if let problem = setup.validateApplicationLocation() {
            return .invalidApplicationLocation(problem)
        }
        if let problem = setup.validateBundledHelper() {
            return .invalidBundledHelper(problem)
        }
        guard setup.canManageLaunchAgent else {
            return .unmanagedWrapper
        }
        switch await setup.syncManagedSkills() {
        case .synced:
            break
        case .failed(let message):
            return .managedSkillSyncFailed(message)
        }

        let outcome = await InstallLaunchAgentRunner.ensureLoaded(
            manager: setup.launchAgentManager,
            plistPath: setup.launchAgentPlistPath,
            label: setup.launchAgentLabel
        )
        guard outcome == .ok || outcome == .alreadyLoaded else {
            return .launchAgentFailed(outcome)
        }
        let health = await ServerHealthAwaiter.waitForHealthy(setup: setup)
        guard case .success = health else {
            return .unhealthy(health)
        }
        MacAppStartupMaintenance.recordCurrentVersion(setup: setup)
        return .ok
    }
}
