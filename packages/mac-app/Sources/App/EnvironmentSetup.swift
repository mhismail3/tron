import Foundation
import SwiftUI

/// Dependency injection point for the Mac wrapper.
///
/// This is the composition seam for wizard/menu dependencies that need host
/// substitution. Leaf services retain their own bounded filesystem, process,
/// and timing behavior.
struct EnvironmentSetup: Sendable {
    var tronHome: URL
    var applicationBundle: URL
    var bearerTokenPath: URL
    var onboardedMarkerPath: URL
    var networkCachePath: URL
    var launchAgentPlistPath: URL

    var launchAgentLabel: String
    var serverPort: Int
    var canManageLaunchAgent: Bool
    var wrapperLockPath: URL

    /// Returns true if the on-disk first-run sentinel exists.
    var onboardedSentinelExists: @Sendable () -> Bool

    /// Reads the gateway-local health token from `gateway/local-auth.json`.
    /// It is used only by this signed wrapper and never shown to users.
    var readBearerToken: @Sendable () -> String?

    /// Reads the short-lived one-time code emitted for mobile enrollment.
    var readEnrollmentCode: @Sendable () -> String? = { nil }

    /// Reads the disposable Tailscale presentation cache. Pairing resolves
    /// Tailscale live first.
    var readTailscaleIPFromSettings: @Sendable () -> String?

    /// Updates the disposable Tailscale presentation cache. Pairing must not
    /// depend on this write succeeding.
    var cacheTailscaleIP: @Sendable (String) -> Void

    /// Probes Tailscale on the host - app installed AND `tailscale ip -4`
    /// returns at least one address.
    var probeTailscale: @Sendable () async -> TailscaleStatus

    /// Probes wizard permissions from the wrapper process.
    /// The LaunchAgent associates the helper with the wrapper bundle IDs,
    /// so macOS presents and evaluates the TCC row under `Tron.app`
    /// / `TronMac.app`. Keeping probes here avoids a stale helper row in
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

    /// Returns a user-facing problem when the embedded Gateway entrypoint,
    /// production dependencies, or architecture-specific Node runtime is
    /// missing. The shipped app must not depend on a global Pi or Node install.
    var validateGatewayPayload: @Sendable () -> String? = { nil }

    /// Performs a single `system::ping` against the running server.
    /// Returns a classified `ServerPingResult` so the caller can
    /// distinguish "server is down" from "token rejected" — the menu
    /// bar tone + wizard recovery copy depend on this distinction.
    /// Honors the supplied bearer token. `nil` means the token could not be
    /// read locally; authenticated servers should classify that as
    /// `.unauthorized`.
    var pingServer: @Sendable (String?) async -> ServerPingResult

    /// Requests the Gateway-owned drain restart. This is deliberately separate
    /// from LaunchAgent registration: launchd remains the process supervisor.
    var restartGateway: @Sendable () async throws -> GatewayRestartClient.Response = {
        throw GatewayRestartClient.Failure.transport
    }

    /// Health wait policy after menu-bar start/restart/resume actions.
    /// Tests can lower these to keep stale-helper paths deterministic.
    var serverStartHealthCheckAttempts: Int = 60
    var serverStartHealthCheckDelayNanoseconds: UInt64 = 1_000_000_000

    /// LaunchAgent control surface - load/unload/restart/check.
    var launchAgentManager: LaunchAgentManaging

    /// Touches the `~/.tron/internal/run/.onboarded` sentinel atomically.
    var touchOnboardedSentinel: @Sendable () throws -> Void

    /// Current app version identity and the last version whose menu-bar
    /// startup finalized the bundled server.
    var currentAppVersion: @Sendable () -> MacAppVersionIdentity = {
        MacAppVersionIdentity.current()
    }
    var readRecordedAppVersion: @Sendable () -> MacAppVersionIdentity? = {
        MacAppVersionMarkerStore.read(at: TronPaths.macAppVersionMarkerPath)
    }
    var writeRecordedAppVersion: @Sendable (MacAppVersionIdentity) throws -> Void = { version in
        try MacAppVersionMarkerStore.write(version, at: TronPaths.macAppVersionMarkerPath)
    }

    static let live = EnvironmentSetup(
        tronHome: TronPaths.tronHome,
        applicationBundle: TronPaths.applicationBundle,
        bearerTokenPath: TronPaths.bearerTokenPath,
        onboardedMarkerPath: TronPaths.onboardedMarkerPath,
        networkCachePath: TronPaths.networkCachePath,
        launchAgentPlistPath: TronPaths.launchAgentPlistPath,
        launchAgentLabel: TronPaths.launchAgentLabel,
        serverPort: TronPaths.defaultServerPort,
        canManageLaunchAgent: TronPaths.canManageLaunchAgent,
        wrapperLockPath: TronPaths.macWrapperLockPath,
        onboardedSentinelExists: {
            FileManager.default.fileExists(atPath: TronPaths.onboardedMarkerPath.path)
        },
        readBearerToken: {
            BearerTokenReader.read(at: TronPaths.bearerTokenPath)
        },
        readEnrollmentCode: {
            EnrollmentCodeReader.read(at: TronPaths.enrollmentCodePath)
        },
        readTailscaleIPFromSettings: {
            GatewayNetworkCacheReader.tailscaleIP(at: TronPaths.networkCachePath)
        },
        cacheTailscaleIP: { ip in
            do {
                try GatewayNetworkCacheWriter.cacheTailscaleIP(ip, at: TronPaths.networkCachePath)
            } catch {
                NSLog(
                    "[EnvironmentSetup] failed to cache Tailscale IP in %@: %@",
                    TronPaths.networkCachePath.path,
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
            ExistingInstallDetector.detect(
                gatewayPayloadProblemResolver: { ExistingInstallDetector.validateGatewayPayload() }
            )
        },
        validateApplicationLocation: {
            MacRuntimeVariant.detect().locationProblem
        },
        validateBundledHelper: {
            ExistingInstallDetector.validateBundledHelper()
        },
        validateGatewayPayload: {
            ExistingInstallDetector.validateGatewayPayload()
        },
        pingServer: { token in
            let tailscale = await TailscaleProbe.probe()
            let host = tailscale.displayIP
                ?? GatewayNetworkCacheReader.tailscaleIP(at: TronPaths.networkCachePath)
                ?? "127.0.0.1"
            return await ServerPing.ping(host: host, port: TronPaths.defaultServerPort, token: token)
        },
        restartGateway: {
            let tailscale = await TailscaleProbe.probe()
            let host = tailscale.displayIP
                ?? GatewayNetworkCacheReader.tailscaleIP(at: TronPaths.networkCachePath)
                ?? "127.0.0.1"
            return try await GatewayRestartClient.restart(
                host: host,
                port: TronPaths.defaultServerPort,
                token: BearerTokenReader.read(at: TronPaths.bearerTokenPath)
            )
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
