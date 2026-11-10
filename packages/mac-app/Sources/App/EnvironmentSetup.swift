import Foundation
import SwiftUI

struct EnvironmentSetup: Sendable {
    var profile: TronGatewayProfile = .stable
    var runtimeVariant: MacRuntimeVariant = .installedRelease
    var tronHome: URL
    var applicationBundle: URL
    var bearerTokenPath: URL
    var onboardedMarkerPath: URL
    var networkCachePath: URL
    var launchAgentPlistPath: URL

    var launchAgentLabel: String
    var serverPort: Int
    var launchAgentServiceStatus: @Sendable () -> ExistingInstallDetector.ServiceRegistrationStatus = {
        .unknown("Tron Agent approval could not be inspected")
    }
    var openLoginItemsSettings: @Sendable () -> Void = {}
    var canManageLaunchAgent: Bool
    var wrapperLockPath: URL

    var onboardedSentinelExists: @Sendable () -> Bool

    var readBearerToken: @Sendable () -> String?

    var runtimeOwnershipHealthy: @Sendable () async -> Bool = { false }

    var admitStableRuntime: @Sendable (ServerPingInfo) async -> Result<StableGatewayObserver.Admission, StableGatewayObserver.Refusal> = { _ in .failure(.noRuntime) }

    var observeDebugGateway: @Sendable (String?) async -> DebugGatewayObserver.Observation = { _ in .unavailable }

    var readEnrollmentCode: @Sendable () -> String? = { nil }

    var readTailscaleIPFromSettings: @Sendable () -> String?

    var cacheTailscaleIP: @Sendable (String) -> Void

    var probeTailscale: @Sendable () async -> TailscaleStatus

    var probePermissions: @Sendable () async -> [Permission: PermissionStatus]

    var nativeHostServiceState: @Sendable () async -> NativeHostServiceState = { .unavailable }
    var enableNativeHost: @Sendable () async throws -> NativeHostServiceState = { .unavailable }
    var refreshNativeHost: @Sendable () async throws -> NativeHostServiceState = { .unavailable }
    var requestPermission: @Sendable (Permission) async -> PermissionStatus = { _ in .probeUnavailable }
    var unregisterNativeHost: @Sendable () async throws -> Void = {}

    var detectExistingInstall: @Sendable () async -> ExistingInstallStatus

    var validateApplicationLocation: @Sendable () -> String?

    var validateBundledHelper: @Sendable () async -> String?

    var validateGatewayPayload: @Sendable () -> String? = { nil }

    var pingServer: @Sendable (String?) async -> ServerPingResult

    var statusPollPingServer: (@Sendable (String?) async -> ServerPingResult)?

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
    var readDrainForQuit: @Sendable () async throws -> GatewayStopClient.Drain = {
        throw GatewayRestartClient.Failure.transport
    }
    var readRuntimeForQuit: @Sendable () async throws -> LaunchAgentRuntimeInfo? = {
        throw LaunchAgentRuntimeReader.ObservationFailure.unavailable
    }
    var retireCompletedGatewayForQuit: @Sendable (Int, String, String) async throws -> Void = { _, _, _ in
        throw MacQuitCoordinator.Failure.unmanaged
    }
    var retireNativeHostForQuit: @Sendable () async throws -> Void = {
        throw NativeHostError.serviceUnavailable
    }
    var restoreApprovedNativeHost: @Sendable () async -> Void = {}

    var serverStartHealthCheckAttempts: Int = 60
    var serverStartHealthCheckDelayNanoseconds: UInt64 = 1_000_000_000

    var launchAgentManager: LaunchAgentManaging

    var touchOnboardedSentinel: @Sendable () throws -> Void

    var currentAppVersion: @Sendable () -> MacAppVersionIdentity = {
        MacAppVersionIdentity.current()
    }
    var readRecordedAppVersion: @Sendable () -> MacAppVersionIdentity? = {
        MacAppVersionMarkerStore.read(at: TronPaths.macAppVersionMarkerPath)
    }
    var writeRecordedAppVersion: @Sendable (MacAppVersionIdentity) throws -> Void = { version in
        try MacAppVersionMarkerStore.write(version, at: TronPaths.macAppVersionMarkerPath)
    }

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

    func resolvedTailscaleHost() async -> String? {
        await TailscaleHostResolution.resolveLive(probe: probeTailscale, cache: readTailscaleIPFromSettings)
    }

    static let live = makeLive(profile: .stable)
    static let debug = makeDebugObserver()

    private static func makeLive(profile: TronGatewayProfile) -> EnvironmentSetup {
        let home = TronPaths.tronHome(profile: profile)
        _ = TronPaths.agentHome(profile: profile)
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
            applicationBundle: TronPaths.applicationBundle,
            bearerTokenPath: bearer,
            onboardedMarkerPath: marker,
            networkCachePath: cache,
            launchAgentPlistPath: plist,
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
            readDrainForQuit: {
                guard let host = await resolveHost() else { throw GatewayRestartClient.Failure.transport }
                return try await GatewayStopClient.drain(
                    host: host, port: profile.port, token: BearerTokenReader.read(at: bearer)
                )
            },
            readRuntimeForQuit: { try await LaunchAgentRuntimeReader.read(label: profile.launchAgentLabel) },
            retireCompletedGatewayForQuit: { pid, command, start in
                guard TronPaths.canManageLaunchAgent(profile: profile) else { throw MacQuitCoordinator.Failure.unmanaged }
                try await MacQuitCoordinator.retireCompletedGateway(
                    label: profile.launchAgentLabel, pid: pid, command: command, start: start
                )
            },
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
            applicationBundle: TronPaths.applicationBundle,
            bearerTokenPath: bearer,
            onboardedMarkerPath: marker,
            networkCachePath: cache,
            launchAgentPlistPath: TronPaths.launchAgentPlistPath(profile: profile),
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

private struct EnvironmentSetupKey: EnvironmentKey {
    static let defaultValue: EnvironmentSetup = .live
}

extension EnvironmentValues {
    var environmentSetup: EnvironmentSetup {
        get { self[EnvironmentSetupKey.self] }
        set { self[EnvironmentSetupKey.self] = newValue }
    }
}
