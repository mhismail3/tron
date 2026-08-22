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

struct LaunchAgentRuntimeInfo: Equatable, Sendable {
    var pid: Int?
    var uptime: String?
    var parentBundleIdentifier: String?
    var parentBundleVersion: String?
    var executablePath: String?
    var bundleProgram: String?
    /// Exact `ps -ww` command for the launchd-owned PID. Relative
    /// BundleProgram metadata alone cannot prove which payload was exec'd.
    var processCommand: String?
    var gatewaySupervisionMarker: String?
    var gatewayChannelMarker: String?
    var needsLaunchConstraintRefresh: Bool

    init(
        pid: Int? = nil,
        uptime: String? = nil,
        parentBundleIdentifier: String? = nil,
        parentBundleVersion: String? = nil,
        executablePath: String? = nil,
        bundleProgram: String? = nil,
        processCommand: String? = nil,
        gatewaySupervisionMarker: String? = nil,
        gatewayChannelMarker: String? = nil,
        needsLaunchConstraintRefresh: Bool = false
    ) {
        self.pid = pid
        self.uptime = uptime
        self.parentBundleIdentifier = parentBundleIdentifier
        self.parentBundleVersion = parentBundleVersion
        self.executablePath = executablePath
        self.bundleProgram = bundleProgram
        self.processCommand = processCommand
        self.gatewaySupervisionMarker = gatewaySupervisionMarker
        self.gatewayChannelMarker = gatewayChannelMarker
        self.needsLaunchConstraintRefresh = needsLaunchConstraintRefresh
    }
}

/// Pure registration decision. The plan is computed from one launchd status,
/// one runtime metadata snapshot, and the current wrapper authority; execution
/// never re-derives ownership between operations.
enum LaunchAgentRegistrationPlan: Equatable, Sendable {
    enum Step: Equatable, Sendable { case bootout, unregister, register, refresh }
    case keep
    case refuse(message: String)
    case takeover(steps: [Step])
    case bootout(steps: [Step])
    case unregister(steps: [Step])
    case register(steps: [Step])
    case refresh(steps: [Step])

    var steps: [Step] {
        switch self {
        case .keep, .refuse: return []
        case .takeover(let steps), .bootout(let steps), .unregister(let steps),
             .register(let steps), .refresh(let steps): return steps
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

    /// Explicit process restart used only by lifecycle flows that cannot use
    /// the Gateway's authenticated drain command (for example permissions).
    func restart(label: String) async -> LaunchAgentOutcome

    /// True if `launchctl print gui/$UID/<label>` returns a state row.
    /// Cheaper than load+ping when you only need a yes/no.
    func isLoaded(label: String) async -> Bool

    /// True when ServiceManagement still has a registration, even if launchd
    /// has not loaded the process yet.
    func isRegistered(label: String) async -> Bool

    /// Best-effort process metadata from launchd/ps for diagnostics UI.
    /// Returns nil when launchd has no loaded service or does not expose a pid.
    func runtimeInfo(label: String) async -> LaunchAgentRuntimeInfo?
}

/// Applies the shared service-start policy for registration/start flows.
/// The menu-bar Restart action deliberately does not use this helper: it asks
/// the supervised Gateway to drain and lets launchd perform relaunch.
extension LaunchAgentManaging {
    func isRegistered(label: String) async -> Bool {
        await isLoaded(label: label)
    }
}

enum LaunchAgentLoader {
    static func ensureLoaded(
        manager: LaunchAgentManaging,
        plistPath: URL,
        label: String
    ) async -> LaunchAgentOutcome {
        let loadOutcome = await manager.load(plistPath: plistPath, label: label)
        guard case .alreadyLoaded = loadOutcome else {
            return loadOutcome
        }
        return await manager.restart(label: label)
    }
}
