import Foundation

/// Outcome of a launchctl operation. Distinguishes "the agent is loaded
/// and the binary is up" from "we asked launchd nicely but the unit
/// failed to start".
enum LaunchAgentOutcome: Equatable, Sendable {
    case ok
    case alreadyLoaded
    case requiresApproval(message: String)
    case launchdRefused(message: String)
    case binaryMissing(path: String)
    case unknown(message: String)
}

/// Registration decision from one status/runtime snapshot, application identity,
/// helper presence and wrapper authority. Only real operations enter the list;
/// execution never re-derives policy between them.
enum LaunchAgentRegistrationPlan: Equatable, Sendable {
    enum Step: Equatable, Sendable { case bootout, unregister, register }
    case keep
    case refuse(message: String)
    case change(steps: [Step])

    var steps: [Step] {
        switch self {
        case .keep, .refuse: return []
        case .change(let steps): return steps
        }
    }
}

/// Indirection over `SMAppService` and launchd diagnostics so service-control
/// callers are testable without mutating Login Items.
/// Mocks live in `Tests/Infrastructure/Fakes/MockLaunchAgentManager.swift`.
protocol LaunchAgentManaging: Sendable {
    /// `SMAppService.agent(plistName:).register()` — registers the
    /// bundled LaunchAgent. Returns `.requiresApproval` when macOS is
    /// waiting for the user to approve the Login Item.
    func load(plistPath: URL, label: String) async -> LaunchAgentOutcome

    /// `SMAppService.agent(plistName:).unregister()` — removes the
    /// bundled Login Item registration. Safe to call when not registered.
    func unload(label: String) async -> LaunchAgentOutcome

    /// Starts an already-registered, stopped agent without terminating a
    /// concurrently starting process. The live implementation admits the
    /// registration again immediately before issuing a non-destructive kick.
    func start(label: String) async -> LaunchAgentOutcome

    /// True if `launchctl print gui/$UID/<label>` returns a state row.
    /// Nil means the observation failed; it is not proof that the job is absent.
    func isLoaded(label: String) async -> Bool?

    /// True when ServiceManagement still has a registration, even if launchd
    /// has not loaded the process yet.
    func isRegistered(label: String) async -> Bool

    /// Best-effort process metadata from launchd/ps for diagnostics UI.
    /// Returns nil when launchd has no loaded service or does not expose a pid.
    func runtimeInfo(label: String) async -> LaunchAgentRuntimeInfo?
}

/// Applies the shared service-start policy for registration/start flows.
/// An already-loaded registration is admitted and started non-destructively;
/// lifecycle callers use the authenticated Gateway drain for running work.
enum LaunchAgentLoader {
    static func ensureLoaded(
        manager: LaunchAgentManaging,
        plistPath: URL,
        label: String
    ) async -> LaunchAgentOutcome {
        let loadOutcome = await manager.load(plistPath: plistPath, label: label)
        guard case .alreadyLoaded = loadOutcome else { return loadOutcome }
        return await manager.start(label: label)
    }
}
