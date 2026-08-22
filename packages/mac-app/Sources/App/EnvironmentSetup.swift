import Foundation
import SwiftUI

/// Dependency injection point for the Mac wrapper.
///
/// This is the composition seam for wizard/menu dependencies that need host
/// substitution. Leaf services retain their own bounded filesystem, process,
/// and timing behavior.
struct EnvironmentSetup: Sendable {
    var profile: TronGatewayProfile = .stable
    var runtimeVariant: MacRuntimeVariant = .installedRelease
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

    /// Projects authoritative LaunchAgent ownership for Stable lifecycle actions.
    /// Read-only Debug observation deliberately leaves this false.
    var runtimeOwnershipHealthy: @Sendable () async -> Bool = { false }

    /// Coherent Stable admission correlating launchd, listener, payload,
    /// process command, and authenticated identity.
    var admitStableRuntime: @Sendable (ServerPingInfo) async -> StableGatewayObserver.Admission? = { _ in nil }

    /// One-shot read-only Debug observation. It owns transport resolution and
    /// returns one immutable admission rather than exposing split projections.
    var observeDebugGateway: @Sendable (String?) async -> DebugGatewayObserver.Observation = { _ in .unavailable }

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

    /// Resolves startup once from the bundle variant, command line, test host,
    /// and authoritative onboarding sentinel.
    func resolvedStartupMode(
        command: MacCommandLineMode = .current,
        underTests: Bool = TronMacRuntime.isRunningUnderTests(),
        onboardedOverride: Bool? = nil
    ) -> MacStartupMode {
        MacStartupMode.resolve(
            variant: runtimeVariant,
            onboarded: onboardedOverride ?? onboardedSentinelExists(),
            command: command,
            underTests: underTests
        )
    }

    /// Resolves the Gateway's presentation host from the live Tailscale
    /// source, falling back only to the bounded disposable cache.
    func resolvedTailscaleHost() async -> String? {
        let live = await probeTailscale().displayIP
        for candidate in [live, readTailscaleIPFromSettings()] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return nil
    }

    static let live = makeLive(profile: .stable)
    /// Read-only authenticated observation of the scripts/tron-dev runtime.
    static let debug = makeDebugObserver()

    private static func makeLive(profile: TronGatewayProfile) -> EnvironmentSetup {
        let home = TronPaths.tronHome(profile: profile)
        let bearer = TronPaths.bearerTokenPath(profile: profile)
        let enrollment = TronPaths.enrollmentCodePath(profile: profile)
        let cache = TronPaths.networkCachePath(profile: profile)
        let marker = TronPaths.onboardedMarkerPath(profile: profile)
        let plist = TronPaths.launchAgentPlistPath(profile: profile)
        let ownership: @Sendable () async -> Bool = {
            guard profile == .stable,
                  ExistingInstallDetector.serviceStatus(label: profile.launchAgentLabel) == .enabled else { return false }
            guard let selected = StableGatewayObserver.activePayload() else { return false }
            return LiveLaunchAgentManager.runtimeOwnsProfile(
                runtimeInfo: await LiveLaunchAgentManager(profile: profile).runtimeInfo(label: profile.launchAgentLabel),
                profile: profile,
                expectedParentBundleIdentifier: MacRuntimeVariant.releaseBundleIdentifier,
                expectedHelperPath: TronPaths.serverHelperBinary(profile: profile).path,
                expectedPayloadRoot: selected.root
            )
        }
        return EnvironmentSetup(
            profile: profile,
            runtimeVariant: MacRuntimeVariant.detect(),
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
            runtimeOwnershipHealthy: ownership,
            admitStableRuntime: { info in
                await StableGatewayObserver.observe(info: info)
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
                do {
                    return try await ServerPing.ping(host: host, port: profile.port, token: token)
                } catch is CancellationError {
                    return .timeout
                } catch {
                    return .unreachable
                }
            },
            restartGateway: {
                let tailscale = await TailscaleProbe.probe()
                let host = tailscale.displayIP ?? GatewayNetworkCacheReader.tailscaleIP(at: cache) ?? "127.0.0.1"
                return try await GatewayRestartClient.restart(
                    host: host, port: profile.port, token: BearerTokenReader.read(at: bearer)
                )
            },
            launchAgentManager: LiveLaunchAgentManager(profile: profile),
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

    private static func makeDebugObserver() -> EnvironmentSetup {
        let profile = TronGatewayProfile.debug
        let home = TronPaths.tronHome(profile: profile)
        let bearer = TronPaths.bearerTokenPath(profile: profile)
        let enrollment = TronPaths.enrollmentCodePath(profile: profile)
        let cache = TronPaths.networkCachePath(profile: profile)
        let marker = TronPaths.onboardedMarkerPath(profile: profile)
        return EnvironmentSetup(
            profile: profile,
            runtimeVariant: .xcodeDebug,
            tronHome: home,
            agentHome: TronPaths.agentHome(profile: profile),
            applicationBundle: TronPaths.applicationBundle,
            bearerTokenPath: bearer,
            enrollmentCodePath: enrollment,
            onboardedMarkerPath: marker,
            networkCachePath: cache,
            launchAgentPlistPath: TronPaths.launchAgentPlistPath(profile: profile),
            serverHelperBinaryPath: TronPaths.serverHelperBinary(profile: .stable),
            launchAgentLabel: profile.launchAgentLabel,
            serverPort: profile.port,
            canManageLaunchAgent: false,
            wrapperLockPath: TronPaths.macWrapperLockPath(profile: profile),
            onboardedSentinelExists: { FileManager.default.fileExists(atPath: marker.path) },
            readBearerToken: { BearerTokenReader.read(at: bearer) },
            runtimeOwnershipHealthy: { false },
            observeDebugGateway: { token in
                await DebugGatewayObserver.observe(home: home, token: token)
            },
            readEnrollmentCode: { EnrollmentCodeReader.read(at: enrollment) },
            readTailscaleIPFromSettings: { GatewayNetworkCacheReader.tailscaleIP(at: cache) },
            cacheTailscaleIP: { _ in },
            probeTailscale: { await TailscaleProbe.probe() },
            probePermissions: { await MacPermissionProbe.probeAll() },
            detectExistingInstall: { .none },
            validateApplicationLocation: { nil },
            validateBundledHelper: { nil },
            validateGatewayPayload: { nil },
            pingServer: { _ in .unreachable },
            restartGateway: { throw GatewayRestartClient.Failure.transport },
            launchAgentManager: ReadOnlyDebugLaunchAgentManager(),
            touchOnboardedSentinel: {},
            readRecordedAppVersion: { nil },
            writeRecordedAppVersion: { _ in }
        )
    }

    /// Pins a freshly admitted Debug observation into a pairing presentation.
    /// The sheet cannot race a later lifecycle/host transition or reconstruct
    /// identity from independent reads.
    func pinnedDebug(admission: DebugGatewayObserver.Admission) -> EnvironmentSetup {
        precondition(profile == .debug)
        var copy = self
        let observeFresh = observeDebugGateway
        copy.observeDebugGateway = { token in
            switch await observeFresh(token) {
            case .admitted(let current) where current == admission:
                return .admitted(current)
            case .unauthorized:
                return .unauthorized
            case .admitted, .unavailable:
                return .unavailable
            }
        }
        copy.pingServer = { token in
            switch await observeFresh(token) {
            case .admitted(let current) where current == admission: return .success(current.info)
            case .unauthorized: return .unauthorized
            case .admitted, .unavailable: return .unreachable
            }
        }
        copy.readTailscaleIPFromSettings = { admission.transportHost }
        copy.cacheTailscaleIP = { _ in }
        copy.probeTailscale = { .signedIn(address: admission.transportHost) }
        return copy
    }
}

private struct ReadOnlyDebugLaunchAgentManager: LaunchAgentManaging {
    private var refused: LaunchAgentOutcome {
        .launchdRefused(message: "Debug Gateway lifecycle belongs to scripts/tron dev.")
    }

    func load(plistPath: URL, label: String) async -> LaunchAgentOutcome { refused }
    func unload(label: String) async -> LaunchAgentOutcome { refused }
    func restart(label: String) async -> LaunchAgentOutcome { refused }
    func isLoaded(label: String) async -> Bool { false }
    func isRegistered(label: String) async -> Bool { false }
    func runtimeInfo(label: String) async -> LaunchAgentRuntimeInfo? { nil }
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
