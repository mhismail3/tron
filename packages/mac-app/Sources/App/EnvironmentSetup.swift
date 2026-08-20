import Foundation
import SwiftUI

/// Dependency injection point for the Mac wrapper.
///
/// This is the composition seam for wizard/menu dependencies that need host
/// substitution. Leaf services retain their own bounded filesystem, process,
/// and timing behavior.
struct EnvironmentSetup: Sendable {
    var profile: TronGatewayProfile = .stable
    var tronHome: URL
    var agentHome: URL = TronPaths.agentHome(profile: .stable)
    var applicationBundle: URL
    var bearerTokenPath: URL
    var enrollmentCodePath: URL = TronPaths.enrollmentCodePath(profile: .stable)
    var onboardedMarkerPath: URL
    var networkCachePath: URL
    var launchAgentPlistPath: URL
    var serverHelperBinaryPath: URL = TronPaths.serverHelperBinary(profile: .stable)

    var launchAgentLabel: String
    var serverPort: Int
    var canManageLaunchAgent: Bool
    var wrapperLockPath: URL

    /// Returns true if the on-disk first-run sentinel exists.
    var onboardedSentinelExists: @Sendable () -> Bool

    /// Reads the gateway-local health token from `gateway/local-auth.json`.
    /// It is used only by this signed wrapper and never shown to users.
    var readBearerToken: @Sendable () -> String?

    /// Projects the authoritative registered/running LaunchAgent ownership
    /// for pairing. Pairing additionally proves credential health with ping.
    var runtimeOwnershipHealthy: @Sendable () async -> Bool = { false }

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

    /// Release uninstall unregisters an enabled Preview service but never
    /// removes its canonical ~/.tron-dev or ~/.pi/agent-dev data.
    var unregisterPreviewIfEnabled: @Sendable () async -> LaunchAgentOutcome = { .ok }

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

    // Debug isolated composition must resolve every live path to Preview;
    // installed Release remains stable because activeProfile is stable there.
    static let live = makeLive(profile: TronPaths.activeProfile)
    // Release exposes Preview explicitly without changing its own stable
    // credentials, home, or LaunchAgent.
    static let preview = makeLive(profile: .preview)

    private static func makeLive(profile: TronGatewayProfile) -> EnvironmentSetup {
        let home = TronPaths.tronHome(profile: profile)
        let bearer = TronPaths.bearerTokenPath(profile: profile)
        let enrollment = TronPaths.enrollmentCodePath(profile: profile)
        let cache = TronPaths.networkCachePath(profile: profile)
        let marker = TronPaths.onboardedMarkerPath(profile: profile)
        let plist = TronPaths.launchAgentPlistPath(profile: profile)
        let unregisterPreview: @Sendable () async -> LaunchAgentOutcome
        if profile == .stable {
            unregisterPreview = {
                let preview = EnvironmentSetup.preview
                // Unknown is not absence: ask SMAppService to unregister for
                // every non-terminal status so stale registrations cannot
                // survive uninstall. Canonical Preview homes are untouched.
                switch ExistingInstallDetector.serviceStatus(label: preview.launchAgentLabel) {
                case .notRegistered, .notFound: return .ok
                case .enabled, .requiresApproval, .unknown:
                    return await preview.launchAgentManager.unload(label: preview.launchAgentLabel)
                }
            }
        } else {
            unregisterPreview = { .ok }
        }
        return EnvironmentSetup(
            profile: profile,
            tronHome: home,
            agentHome: TronPaths.agentHome(profile: profile),
            applicationBundle: TronPaths.applicationBundle,
            bearerTokenPath: bearer,
            enrollmentCodePath: enrollment,
            onboardedMarkerPath: marker,
            networkCachePath: cache,
            launchAgentPlistPath: plist,
            serverHelperBinaryPath: TronPaths.serverHelperBinary(profile: profile),
            launchAgentLabel: profile.launchAgentLabel,
            serverPort: profile.port,
            canManageLaunchAgent: TronPaths.canManageLaunchAgent(profile: profile),
            wrapperLockPath: TronPaths.macWrapperLockPath(profile: profile),
            onboardedSentinelExists: { FileManager.default.fileExists(atPath: marker.path) },
            readBearerToken: { BearerTokenReader.read(at: bearer) },
            runtimeOwnershipHealthy: {
                guard ExistingInstallDetector.serviceStatus(label: profile.launchAgentLabel) == .enabled else { return false }
                return LiveLaunchAgentManager.runtimeOwnsProfile(
                    runtimeInfo: await LiveLaunchAgentManager(profile: profile).runtimeInfo(label: profile.launchAgentLabel),
                    profile: profile,
                    expectedParentBundleIdentifier: MacRuntimeVariant.detect().expectedParentBundleIdentifier,
                    expectedHelperPath: TronPaths.serverHelperBinary(profile: profile).path
                )
            },
            readEnrollmentCode: { EnrollmentCodeReader.read(at: enrollment) },
            readTailscaleIPFromSettings: { GatewayNetworkCacheReader.tailscaleIP(at: cache) },
            cacheTailscaleIP: { ip in
                try? GatewayNetworkCacheWriter.cacheTailscaleIP(ip, at: cache)
            },
            probeTailscale: { await TailscaleProbe.probe() },
            probePermissions: { await MacPermissionProbe.probeAll() },
            detectExistingInstall: {
                ExistingInstallDetector.detect(
                    helperBundle: TronPaths.serverHelperBundle(profile: profile),
                    helperBinary: TronPaths.serverHelperBinary(profile: profile),
                    plistPath: plist,
                    bundleSignatureProblemResolver: { bundle in
                        ExistingInstallDetector.bundleSignatureProblem(of: bundle, expectedBundleIdentifier: profile.launchAgentLabel)
                    },
                    gatewayPayloadProblemResolver: { ExistingInstallDetector.validateGatewayPayload() },
                    serviceStatusResolver: { ExistingInstallDetector.serviceStatus(label: profile.launchAgentLabel) }
                )
            },
            validateApplicationLocation: { MacRuntimeVariant.detect().locationProblem },
            validateBundledHelper: {
                ExistingInstallDetector.validateBundledHelper(
                    helperBundle: TronPaths.serverHelperBundle(profile: profile),
                    helperBinary: TronPaths.serverHelperBinary(profile: profile),
                    plistPath: plist,
                    profile: profile
                )
            },
            validateGatewayPayload: { ExistingInstallDetector.validateGatewayPayload() },
            pingServer: { token in
                let tailscale = await TailscaleProbe.probe()
                let host = tailscale.displayIP ?? GatewayNetworkCacheReader.tailscaleIP(at: cache) ?? "127.0.0.1"
                return await ServerPing.ping(host: host, port: profile.port, token: token)
            },
            restartGateway: {
                let tailscale = await TailscaleProbe.probe()
                let host = tailscale.displayIP ?? GatewayNetworkCacheReader.tailscaleIP(at: cache) ?? "127.0.0.1"
                return try await GatewayRestartClient.restart(
                    host: host, port: profile.port, token: BearerTokenReader.read(at: bearer)
                )
            },
            launchAgentManager: LiveLaunchAgentManager(profile: profile),
            unregisterPreviewIfEnabled: unregisterPreview,
            touchOnboardedSentinel: { try OnboardedSentinelWriter.touch(at: marker) },
            currentAppVersion: { MacAppVersionIdentity.current() },
            readRecordedAppVersion: {
                MacAppVersionMarkerStore.read(at: TronPaths.macAppVersionMarkerPath(profile: profile))
            },
            writeRecordedAppVersion: { version in
                try MacAppVersionMarkerStore.write(version, at: TronPaths.macAppVersionMarkerPath(profile: profile))
            }
        )
    }
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
