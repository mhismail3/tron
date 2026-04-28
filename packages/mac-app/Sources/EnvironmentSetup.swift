import Foundation
import SwiftUI

/// Dependency injection point for the Mac wrapper.
///
/// All filesystem paths, subprocess invocations, and time sources go
/// through this struct so tests can substitute pure-value fakes
/// without touching the host system.
struct EnvironmentSetup: Sendable {
    var tronHome: URL
    var applicationBundle: URL
    var serverHelperBundle: URL
    var serverHelperBinary: URL
    var bearerTokenPath: URL
    var onboardedMarkerPath: URL
    var settingsPath: URL
    var launchAgentPlistPath: URL

    var serverPort: Int

    /// Returns true if the on-disk first-run sentinel exists.
    var onboardedSentinelExists: @Sendable () -> Bool

    /// Reads the bearer token from `~/.tron/system/auth.json`.
    /// Returns nil if missing/unreadable.
    var readBearerToken: @Sendable () -> String?

    /// Reads `server.tailscaleIp` from `~/.tron/system/settings.json`.
    /// Returns nil if missing/unset. Pairing treats this as a fallback
    /// cache only; fresh installs resolve Tailscale live first.
    var readTailscaleIPFromSettings: @Sendable () -> String?

    /// Writes `server.tailscaleIp` into `~/.tron/system/settings.json`
    /// without disturbing any existing settings. Best-effort cache for
    /// later server/menu-bar reads; pairing must not depend on this
    /// write succeeding.
    var cacheTailscaleIP: @Sendable (String) -> Void

    /// Probes Tailscale on the host - app installed AND `tailscale ip -4`
    /// returns at least one address.
    var probeTailscale: @Sendable () async -> TailscaleStatus

    /// Probes all three wizard permissions from the wrapper process.
    /// The LaunchAgent associates the helper with the wrapper bundle IDs,
    /// so macOS presents and evaluates these TCC rows under `Tron.app`
    /// / `TronMac.app`. Keeping probes here avoids stale helper rows in
    /// System Settings and makes Re-check instantaneous.
    var probePermissions: @Sendable () async -> [Permission: PermissionStatus]

    /// Detects whether the bundled Login Item is registered and usable.
    var detectExistingInstall: @Sendable () -> ExistingInstallStatus

    /// Returns a user-facing problem when the release app is not running
    /// from `/Applications/Tron.app`.
    var validateApplicationLocation: @Sendable () -> String?

    /// Returns a user-facing problem when the embedded helper, LaunchAgent
    /// plist, or helper signature is missing/corrupt.
    var validateBundledHelper: @Sendable () -> String?

    /// Performs a single `system.ping` against the running server.
    /// Returns a classified `ServerPingResult` so the caller can
    /// distinguish "server is down" from "token rejected" — the menu
    /// bar tone + wizard recovery copy depend on this distinction.
    /// Honors the supplied bearer token (nil for legacy unauthenticated
    /// hosts).
    var pingServer: @Sendable (String?) async -> ServerPingResult

    /// LaunchAgent control surface - load/unload/restart/check.
    var launchAgentManager: LaunchAgentManaging

    /// Touches the `~/.tron/system/run/.onboarded` sentinel atomically.
    var touchOnboardedSentinel: @Sendable () throws -> Void

    static let live = EnvironmentSetup(
        tronHome: TronPaths.tronHome,
        applicationBundle: TronPaths.applicationBundle,
        serverHelperBundle: TronPaths.serverHelperBundle,
        serverHelperBinary: TronPaths.serverHelperBinary,
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
        cacheTailscaleIP: { ip in
            do {
                try ServerSettingsWriter.cacheTailscaleIP(ip, at: TronPaths.settingsPath)
            } catch {
                NSLog(
                    "[EnvironmentSetup] failed to cache Tailscale IP in %@: %@",
                    TronPaths.settingsPath.path,
                    error.localizedDescription
                )
            }
        },
        probeTailscale: {
            await TailscaleProbe.probe()
        },
        probePermissions: {
            await MacPermissionProbe.probeAll()
        },
        detectExistingInstall: {
            ExistingInstallDetector.detect()
        },
        validateApplicationLocation: {
            ExistingInstallDetector.validateApplicationLocation()
        },
        validateBundledHelper: {
            ExistingInstallDetector.validateBundledHelper()
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
