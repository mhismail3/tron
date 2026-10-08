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
    var launchAgentServiceStatus: @Sendable () -> ExistingInstallDetector.ServiceRegistrationStatus = {
        .unknown("Tron Agent approval could not be inspected")
    }
    var openLoginItemsSettings: @Sendable () -> Void = {}
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
    /// process command, and authenticated identity, or the check that refused.
    var admitStableRuntime: @Sendable (ServerPingInfo) async -> Result<StableGatewayObserver.Admission, StableGatewayObserver.Refusal> = { _ in .failure(.noRuntime) }

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

    /// Probes FDA from the wrapper and GUI permissions from the signed Aqua
    /// host. No probe requests TCC or registers a service.
    var probePermissions: @Sendable () async -> [Permission: PermissionStatus]

    /// Explicit user-only GUI permission request. The request is never made
    /// by polling, setup readiness, or a view appearance.
    var nativeHostServiceState: @Sendable () async -> NativeHostServiceState = { .unavailable }
    var enableNativeHost: @Sendable () async throws -> NativeHostServiceState = { .unavailable }
    var refreshNativeHost: @Sendable () async throws -> NativeHostServiceState = { .unavailable }
    var requestPermission: @Sendable (Permission) async -> PermissionStatus = { _ in .probeUnavailable }
    var unregisterNativeHost: @Sendable () async throws -> Void = {}

    /// Detects whether the bundled Login Item is registered and usable.
    var detectExistingInstall: @Sendable () async -> ExistingInstallStatus

    /// Returns a user-facing problem when the release app is not running
    /// from `/Applications/Tron.app`.
    var validateApplicationLocation: @Sendable () -> String?

    /// Returns a user-facing problem when the embedded helper, LaunchAgent
    /// plist, or helper signature is missing/corrupt.
    var validateBundledHelper: @Sendable () async -> String?

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
    /// `.unauthorized`. Every explicit user action (pairing, restart, health
    /// wait, menu presentation) pings through this and so resolves Tailscale
    /// live.
    var pingServer: @Sendable (String?) async -> ServerPingResult

    /// The status poll's per-cycle ping. It differs from `pingServer` only in
    /// transport resolution: it reuses one live Tailscale resolution for a
    /// bounded window, so the 30 s poll does not make Tailscale reload its
    /// network extension. `nil` falls back to `pingServer`.
    var statusPollPingServer: (@Sendable (String?) async -> ServerPingResult)?

    /// Requests the Gateway-owned drain restart. This is deliberately separate
    /// from LaunchAgent registration: launchd remains the process supervisor.
    var restartGateway: @Sendable () async throws -> GatewayRestartClient.Response = {
        throw GatewayRestartClient.Failure.transport
    }
    var updateGateway: @Sendable (String) async throws -> GatewayRestartClient.UpdateResponse = { _ in
        throw GatewayRestartClient.Failure.transport
    }
    var gatewayUpdateCommandStatus: @Sendable (String) async throws -> GatewayRestartClient.CommandStatusResponse = { _ in
        throw GatewayRestartClient.Failure.transport
    }
    var stopGateway: @Sendable (String) async throws -> GatewayStopClient.Response = { _ in
        throw GatewayRestartClient.Failure.transport
    }
    var readRuntimeForQuit: @Sendable () async throws -> LaunchAgentRuntimeInfo? = {
        throw LaunchAgentRuntimeReader.ObservationFailure.unavailable
    }
    var retireNativeHostForQuit: @Sendable () async throws -> Void = {
        throw NativeHostError.serviceUnavailable
    }
    var restoreApprovedNativeHost: @Sendable () async -> Void = {}

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

    /// Resolves the Gateway's presentation and transport host from live
    /// Tailscale state, falling back only to the bounded disposable cache.
    /// There is deliberately no loopback fallback for Stable.
    func resolvedTailscaleHost() async -> String? {
        await TailscaleHostResolution.resolveLive(probe: probeTailscale, cache: readTailscaleIPFromSettings)
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
        let resolveHost: @Sendable () async -> String? = {
            await TailscaleHostResolution.resolveLive(
                probe: { await TailscaleProbe.probe() },
                cache: { GatewayNetworkCacheReader.tailscaleIP(at: cache) }
            )
        }
        // Only the status poll reuses one Tailscale resolution for a bounded
        // window; every explicit lifecycle action resolves live through
        // `resolveHost`.
        let tailscaleHost = TailscaleHostResolution(
            probe: { await TailscaleProbe.probe() },
            readCached: { GatewayNetworkCacheReader.tailscaleIP(at: cache) },
            writeCached: { ip in try? GatewayNetworkCacheWriter.cacheTailscaleIP(ip, at: cache) }
        )
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
            launchAgentServiceStatus: { ExistingInstallDetector.serviceStatus(label: profile.launchAgentLabel) },
            openLoginItemsSettings: { LoginItemsSettingsOpener.open() },
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
            probePermissions: {
                var snapshot = await MacPermissionProbe.probeAll()
                let native = await NativeHostCoordinator.shared.probe()
                snapshot.merge(native) { _, native in native }
                return snapshot
            },
            nativeHostServiceState: { await NativeHostCoordinator.shared.serviceState() },
            enableNativeHost: {
                guard TronPaths.canManageLaunchAgent(profile: profile) else { throw NativeHostError.bundleUnavailable }
                return try await NativeHostCoordinator.shared.enable()
            },
            refreshNativeHost: {
                guard TronPaths.canManageLaunchAgent(profile: profile) else { throw NativeHostError.bundleUnavailable }
                return try await NativeHostCoordinator.shared.refresh()
            },
            requestPermission: { permission in
                guard TronPaths.canManageLaunchAgent(profile: profile) else { return .probeUnavailable }
                return await NativeHostCoordinator.shared.request(permission)
            },
            unregisterNativeHost: {
                guard TronPaths.canManageLaunchAgent(profile: profile) else { throw NativeHostError.serviceUnavailable }
                try await NativeHostCoordinator.shared.unregister()
            },
            detectExistingInstall: {
                await ExistingInstallDetector.detect(
                    helperBundle: TronPaths.serverHelperBundle(profile: profile),
                    helperBinary: TronPaths.serverHelperBinary(profile: profile),
                    plistPath: plist,
                    bundleSignatureProblemResolver: { bundle in
                        await ExistingInstallDetector.bundleSignatureProblem(of: bundle, expectedBundleIdentifier: profile.launchAgentLabel)
                    },
                    gatewayPayloadProblemResolver: { ExistingInstallDetector.validateGatewayPayload() },
                    serviceStatusResolver: { ExistingInstallDetector.serviceStatus(label: profile.launchAgentLabel) }
                )
            },
            validateApplicationLocation: { MacRuntimeVariant.detect().locationProblem },
            validateBundledHelper: {
                if let problem = await ExistingInstallDetector.validateBundledHelper(
                    helperBundle: TronPaths.serverHelperBundle(profile: profile),
                    helperBinary: TronPaths.serverHelperBinary(profile: profile),
                    plistPath: plist,
                    profile: profile
                ) { return problem }
                return await ExistingInstallDetector.validateNativeHost()
            },
            validateGatewayPayload: { ExistingInstallDetector.validateGatewayPayload() },
            pingServer: { token in
                guard let host = await resolveHost() else { return .unreachable }
                return await Self.ping(host: host, port: profile.port, token: token)
            },
            statusPollPingServer: { token in
                guard let host = await tailscaleHost.host() else { return .unreachable }
                let result = await Self.ping(host: host, port: profile.port, token: token)
                guard Self.failedAddressLookup(result) else { return result }
                // A reused address can be stale. Re-resolve once before reporting
                // the Gateway down, and re-ping only when the address changed, so
                // a Gateway that is genuinely down does not reload the CLI every
                // cycle.
                guard let retried = await tailscaleHost.host(previousPingFailed: true), retried != host else {
                    return result
                }
                return await Self.ping(host: retried, port: profile.port, token: token)
            },
            restartGateway: {
                let host = await resolveHost()
                guard let host else { throw GatewayRestartClient.Failure.transport }
                return try await GatewayRestartClient.restart(
                    host: host, port: profile.port, token: BearerTokenReader.read(at: bearer)
                )
            },
            updateGateway: { commandID in
                let host = await resolveHost()
                guard let host else { throw GatewayRestartClient.Failure.transport }
                return try await GatewayRestartClient.update(
                    host: host, port: profile.port, token: BearerTokenReader.read(at: bearer), commandID: commandID
                )
            },
            gatewayUpdateCommandStatus: { commandID in
                let host = await resolveHost()
                guard let host else { throw GatewayRestartClient.Failure.transport }
                return try await GatewayRestartClient.commandStatus(
                    host: host, port: profile.port, token: BearerTokenReader.read(at: bearer), commandID: commandID
                )
            },
            stopGateway: { commandID in
                guard let host = await resolveHost() else { throw GatewayRestartClient.Failure.transport }
                return try await GatewayStopClient.stop(
                    host: host, port: profile.port, token: BearerTokenReader.read(at: bearer), commandID: commandID
                )
            },
            readRuntimeForQuit: { try await LaunchAgentRuntimeReader.read(label: profile.launchAgentLabel) },
            retireNativeHostForQuit: {
                guard TronPaths.canManageLaunchAgent(profile: profile) else { throw NativeHostError.serviceUnavailable }
                try await NativeHostCoordinator.shared.retireForQuit()
            },
            restoreApprovedNativeHost: {
                guard TronPaths.canManageLaunchAgent(profile: profile),
                      NativeHostStartupPolicy.shouldRestore(state: await NativeHostCoordinator.shared.serviceState()) else { return }
                _ = await NativeHostCoordinator.shared.probe()
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

    private static func ping(host: String, port: Int, token: String?) async -> ServerPingResult {
        do {
            return try await ServerPing.ping(host: host, port: port, token: token)
        } catch is CancellationError {
            return .timeout
        } catch {
            return .unreachable
        }
    }

    /// True when the ping never reached a Gateway at the address it used, which
    /// is the only case a stale resolved address can explain.
    private static func failedAddressLookup(_ result: ServerPingResult) -> Bool {
        switch result {
        case .unreachable, .timeout: return true
        case .success, .unauthorized, .malformedResponse: return false
        }
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
            launchAgentServiceStatus: { .notRegistered },
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
            updateGateway: { _ in throw GatewayRestartClient.Failure.transport },
            gatewayUpdateCommandStatus: { _ in throw GatewayRestartClient.Failure.transport },
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
    func isLoaded(label: String) async -> Bool? { false }
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
