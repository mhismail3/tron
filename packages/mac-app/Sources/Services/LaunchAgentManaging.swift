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
    var programIdentifier: String?
    var executablePath: String?

    init(
        pid: Int? = nil,
        uptime: String? = nil,
        parentBundleIdentifier: String? = nil,
        parentBundleVersion: String? = nil,
        programIdentifier: String? = nil,
        executablePath: String? = nil
    ) {
        self.pid = pid
        self.uptime = uptime
        self.parentBundleIdentifier = parentBundleIdentifier
        self.parentBundleVersion = parentBundleVersion
        self.programIdentifier = programIdentifier
        self.executablePath = executablePath
    }
}

/// Indirection over `SMAppService` and launchd diagnostics so the
/// wizard's install step is testable without mutating Login Items.
/// Mocks live in `Tests/Mocks/MockLaunchAgentManager.swift`.
protocol LaunchAgentManaging: Sendable {
    /// `SMAppService.agent(plistName:).register()` — registers the
    /// bundled LaunchAgent. Returns `.requiresApproval` when macOS is
    /// waiting for the user to approve the Login Item.
    func load(plistPath: URL, label: String) async -> LaunchAgentOutcome

    /// `SMAppService.agent(plistName:).unregister()` — removes the
    /// bundled Login Item registration. Safe to call when not registered.
    func unload(label: String) async -> LaunchAgentOutcome

    /// `launchctl kickstart -k gui/$UID/<label>` — restarts the agent.
    func restart(label: String) async -> LaunchAgentOutcome

    /// True if `launchctl print gui/$UID/<label>` returns a state row.
    /// Cheaper than load+ping when you only need a yes/no.
    func isLoaded(label: String) async -> Bool

    /// Best-effort process metadata from launchd/ps for diagnostics UI.
    /// Returns nil when launchd has no loaded service or does not expose a pid.
    func runtimeInfo(label: String) async -> LaunchAgentRuntimeInfo?
}
