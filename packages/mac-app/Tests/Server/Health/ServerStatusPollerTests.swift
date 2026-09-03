import Foundation
import Testing
@testable import TronMac

@Suite("ServerStatusPoller — singleSnapshot")
struct ServerStatusPollerTests {
    static func makeSetup(
        token: String? = nil,
        pingResult: ServerPingResult = .unreachable,
        tailscaleFromSettings: String? = nil,
        tailscaleStatus: TailscaleStatus = .notInstalled,
        serverPort: Int = 9847,
        launchAgentLoaded: Bool = false
    ) -> EnvironmentSetup {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let launchAgentManager = MockLaunchAgentManager()
        launchAgentManager.loaded = launchAgentLoaded
        launchAgentManager.runtimeInfo = LaunchAgentRuntimeInfo(
            pid: 16027,
            uptime: "01:07:42",
            parentBundleIdentifier: MacRuntimeVariant.detect().expectedParentBundleIdentifier,
            executablePath: TronPaths.serverHelperBinary(profile: .stable).path,
            gatewaySupervisionMarker: TronPaths.gatewaySupervisionValue,
            gatewayChannelMarker: TronGatewayProfile.stable.channel
        )
        return EnvironmentSetup(
            tronHome: tmp,
            applicationBundle: tmp,
            bearerTokenPath: tmp,
            onboardedMarkerPath: tmp,
            networkCachePath: tmp,
            launchAgentPlistPath: tmp,
            launchAgentLabel: "com.tron.server",
            serverPort: serverPort,
            canManageLaunchAgent: true,
            wrapperLockPath: tmp.appendingPathComponent(".mac-wrapper.com.tron.mac.lock"),
            onboardedSentinelExists: { false },
            readBearerToken: { token },
            admitStableRuntime: { info in
                StableGatewayObserver.Admission(
                    processID: 16027,
                    uptime: "01:07:42",
                    payload: GatewayPayloadValidationResult(
                        root: tmp,
                        manifest: GatewayPayloadManifest(
                            channel: "stable", version: "test", gatewayVersion: info.version,
                            nodeVersion: "22", sourceRevision: "revision", runtimeEpoch: "epoch",
                            payloadFingerprint: String(repeating: "a", count: 64)
                        )
                    ),
                    info: info
                )
            },
            readTailscaleIPFromSettings: { tailscaleFromSettings },
            cacheTailscaleIP: { _ in },
            probeTailscale: { tailscaleStatus },
            probePermissions: { [:] },
            detectExistingInstall: { .none },
            validateApplicationLocation: { nil },
            validateBundledHelper: { nil },
            pingServer: { receivedToken in
                #expect(receivedToken == token)
                return pingResult
            },
            launchAgentManager: launchAgentManager,
            touchOnboardedSentinel: { }
        )
    }

    @Test("Stable host resolution fails closed without a Tailscale address")
    func stableHostResolutionFailsClosed() async {
        let setup = Self.makeSetup(
            tailscaleFromSettings: "127.0.0.1",
            tailscaleStatus: .signedIn(address: "127.0.0.1")
        )
        #expect(await setup.resolvedTailscaleHost() == nil)
    }

    @Test("running: ping succeeds, snapshot is .running with version + port")
    func runningSnapshot() async throws {
        let setup = Self.makeSetup(
            token: "abc123",
            pingResult: .success(ServerPingInfo(version: "0.5.0", gatewayChannel: "stable")),
            tailscaleFromSettings: "100.64.0.1",
            serverPort: 19047
        )
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.state.tone == .running)
        #expect(snapshot.state == .running(version: "0.5.0", port: 19047))
        #expect(snapshot.tailscaleIP == "100.64.0.1")
        #expect(snapshot.processID == 16027)
        #expect(snapshot.uptime == "01:07:42")
    }

    @Test("read-only Debug health fails closed when provenance is not admitted")
    func debugProvenanceMismatch() async {
        var setup = Self.makeSetup(
            token: "debug-token",
            pingResult: .success(ServerPingInfo(
                version: "0.5.0",
                gatewayChannel: "dev",
                sourceRevision: "revision",
                buildFingerprint: String(repeating: "a", count: 64),
                runtimeEpoch: "epoch"
            )),
            serverPort: 9848
        )
        setup.profile = .debug
        setup.canManageLaunchAgent = false
        setup.observeDebugGateway = { _ in .unavailable }
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.state == .paused)
    }

    @Test("unreachable + launchd unloaded: paused")
    func pausedSnapshotWhenLaunchdUnloaded() async throws {
        let setup = Self.makeSetup(token: nil, pingResult: .unreachable)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.state == .paused)
        #expect(snapshot.state.tone == .paused)
    }

    @Test("unreachable + launchd loaded: failed")
    func failedSnapshotWhenLaunchdLoaded() async throws {
        let setup = Self.makeSetup(token: "abc123", pingResult: .unreachable, launchAgentLoaded: true)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.state == .failed(reason: "unreachable"))
        #expect(snapshot.state.tone == .failed)
    }

    @Test("timeout + launchd loaded maps to failed")
    func timeoutSnapshot() async throws {
        let setup = Self.makeSetup(token: "abc123", pingResult: .timeout, launchAgentLoaded: true)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.state == .failed(reason: "timeout"))
    }

    @Test("explicit unauthorized maps to attention regardless of token presence")
    func unauthorizedSnapshot() async throws {
        let setup = Self.makeSetup(token: "abc123", pingResult: .unauthorized)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.state == .unauthorized)
        #expect(snapshot.state.tone == .attention)
    }

    @Test("malformed response + launchd loaded maps to failed")
    func malformedSnapshot() async throws {
        let setup = Self.makeSetup(token: "abc", pingResult: .malformedResponse, launchAgentLoaded: true)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.state == .failed(reason: "malformed response"))
    }

    @Test("uses cached engine settings Tailscale IP when server doesn't report one")
    func cachedTailscaleFromSettings() async throws {
        let setup = Self.makeSetup(
            token: "abc",
            pingResult: .success(ServerPingInfo(version: "0.5.0", gatewayChannel: "stable")),
            tailscaleFromSettings: "100.99.99.99"
        )
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.tailscaleIP == "100.99.99.99")
    }
}
