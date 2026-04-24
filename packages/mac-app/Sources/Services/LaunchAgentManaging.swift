import Foundation

/// Outcome of a launchctl operation. Distinguishes "the agent is loaded
/// and the binary is up" from "we asked launchd nicely but the unit
/// failed to start".
enum LaunchAgentOutcome: Equatable, Sendable {
    case ok
    case alreadyLoaded
    case launchdRefused(message: String)
    case binaryMissing(path: String)
    case unknown(message: String)
}

/// Indirection over `launchctl` so the wizard's install step is
/// testable without actually invoking the system launchd. Mocks live in
/// `Tests/Mocks/MockLaunchAgentManager.swift`.
protocol LaunchAgentManaging: Sendable {
    /// `launchctl bootstrap gui/$UID/<plistPath>` — installs the agent.
    /// Returns `.alreadyLoaded` if launchd already has the label. The
    /// install wizard treats that as a stale-job signal and follows with
    /// `restart(label:)` so launchd consumes the plist/binary just written.
    func load(plistPath: URL, label: String) async -> LaunchAgentOutcome

    /// `launchctl bootout gui/$UID/<label>` — removes the agent. Safe to
    /// call when not loaded.
    func unload(label: String) async -> LaunchAgentOutcome

    /// `launchctl kickstart -k gui/$UID/<label>` — restarts the agent.
    func restart(label: String) async -> LaunchAgentOutcome

    /// True if `launchctl print gui/$UID/<label>` returns a state row.
    /// Cheaper than load+ping when you only need a yes/no.
    func isLoaded(label: String) async -> Bool
}
