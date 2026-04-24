import Foundation
import SwiftUI

/// Dependency injection point for the Mac wrapper.
///
/// All filesystem paths, subprocess invocations, and time sources go
/// through this struct so tests can substitute pure-value fakes
/// without touching the host system.
struct EnvironmentSetup: Sendable {
    var tronHome: URL
    var installedBundle: URL
    var installedBinary: URL
    var bearerTokenPath: URL
    var onboardedMarkerPath: URL
    var settingsPath: URL
    var launchAgentPlistPath: URL

    var serverPort: Int

    /// Returns true if the on-disk first-run sentinel exists.
    var onboardedSentinelExists: @Sendable () -> Bool

    /// Reads the bearer token from `~/.tron/system/auth-token.json`.
    /// Returns nil if missing/unreadable.
    var readBearerToken: @Sendable () -> String?

    /// Reads `server.tailscaleIp` from `~/.tron/system/settings.json`.
    /// Returns nil if missing/unset.
    var readTailscaleIPFromSettings: @Sendable () -> String?

    /// Probes Tailscale on the host - app installed AND `tailscale ip -4`
    /// returns at least one address.
    var probeTailscale: @Sendable () async -> TailscaleStatus

    /// Probes the three onboarding-relevant TCC permissions. None of the
    /// probes block; "notDetermined" means the user has not yet been
    /// prompted by Settings.
    var probePermission: @Sendable (Permission) async -> PermissionStatus

    /// Probes all three wizard permissions against the AGENT process
    /// via `system.probePermissions`. The agent is the binary that
    /// actually runs the Computer-Use tool and the filesystem tools, so
    /// this is the authoritative read for the Permissions wizard step.
    /// Returns `.probeUnavailable` per-permission when the server is
    /// unreachable (e.g. mid-`launchctl kickstart`).
    var probeAgentPermissions: @Sendable () async -> [Permission: PermissionStatus]

    /// Detects whether a CLI-installed Tron is already present at the
    /// canonical paths.
    var detectExistingInstall: @Sendable () -> ExistingInstallStatus

    /// Performs a single `system.ping` against the running server.
    /// Returns a classified `ServerPingResult` so the caller can
    /// distinguish "server is down" from "token rejected" — the menu
    /// bar tone + wizard recovery copy depend on this distinction.
    /// Honors the supplied bearer token (nil for legacy unauthenticated
    /// hosts).
    var pingServer: @Sendable (String?) async -> ServerPingResult

    /// LaunchAgent control surface - load/unload/restart/check.
    var launchAgentManager: LaunchAgentManaging

    /// Touches the `.onboarded` sentinel atomically.
    var touchOnboardedSentinel: @Sendable () throws -> Void

    static let live = EnvironmentSetup(
        tronHome: TronPaths.tronHome,
        installedBundle: TronPaths.installedBundle,
        installedBinary: TronPaths.installedBinary,
        bearerTokenPath: TronPaths.bearerTokenPath,
        onboardedMarkerPath: TronPaths.onboardedMarkerPath,
        settingsPath: TronPaths.settingsPath,
        launchAgentPlistPath: TronPaths.launchAgentPlistPath,
        serverPort: TronPaths.defaultServerPort,
        onboardedSentinelExists: {
            FileManager.default.fileExists(atPath: TronPaths.onboardedMarkerPath.path)
        },
        readBearerToken: {
            BearerTokenReader.read(at: TronPaths.bearerTokenPath)
        },
        readTailscaleIPFromSettings: {
            ServerSettingsReader.tailscaleIP(at: TronPaths.settingsPath)
        },
        probeTailscale: {
            await TailscaleProbe.probe()
        },
        probePermission: { permission in
            await PermissionProbe.probe(permission)
        },
        probeAgentPermissions: {
            await PermissionProbeRPC.probeAll(
                host: "127.0.0.1",
                port: TronPaths.defaultServerPort,
                token: BearerTokenReader.read(at: TronPaths.bearerTokenPath)
            )
        },
        detectExistingInstall: {
            ExistingInstallDetector.detect()
        },
        pingServer: { token in
            await ServerPing.ping(host: "127.0.0.1", port: TronPaths.defaultServerPort, token: token)
        },
        launchAgentManager: LiveLaunchAgentManager(),
        touchOnboardedSentinel: {
            try OnboardedSentinelWriter.touch(at: TronPaths.onboardedMarkerPath)
        }
    )
}

// MARK: - SwiftUI Environment plumbing

private struct EnvironmentSetupKey: EnvironmentKey {
    static let defaultValue: EnvironmentSetup = .live
}

extension EnvironmentValues {
    var environmentSetup: EnvironmentSetup {
        get { self[EnvironmentSetupKey.self] }
        set { self[EnvironmentSetupKey.self] = newValue }
    }
}
