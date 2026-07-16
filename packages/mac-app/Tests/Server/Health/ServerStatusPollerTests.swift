import Foundation
import Testing
@testable import TronMac

@Suite("ServerStatusPoller — singleSnapshot")
struct ServerStatusPollerTests {
    static func makeSetup(
        token: String? = nil,
        pingResult: ServerPingResult = .unreachable,
        tailscaleFromSettings: String? = nil,
        serverPort: Int = 9847,
        launchAgentLoaded: Bool = false,
        serverProcess: ServerProcessInfo? = nil
    ) -> EnvironmentSetup {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let launchAgentManager = MockLaunchAgentManager()
        launchAgentManager.loaded = launchAgentLoaded
        launchAgentManager.runtimeInfo = LaunchAgentRuntimeInfo(pid: 16027, uptime: "01:07:42")
        return EnvironmentSetup(
            tronHome: tmp,
            applicationBundle: tmp,
            bearerTokenPath: tmp,
            onboardedMarkerPath: tmp,
            settingsPath: tmp,
            launchAgentPlistPath: tmp,
            launchAgentLabel: "com.tron.server",
            serverPort: serverPort,
            canManageLaunchAgent: true,
            wrapperLockPath: tmp.appendingPathComponent(".mac-wrapper.com.tron.mac.lock"),
            onboardedSentinelExists: { false },
            readBearerToken: { token },
            readTailscaleIPFromSettings: { tailscaleFromSettings },
            cacheTailscaleIP: { _ in },
            probeTailscale: { .notInstalled },
            probePermissions: { [:] },
            detectExistingInstall: { .none },
            validateApplicationLocation: { nil },
            validateBundledHelper: { nil },
            pingServer: { receivedToken in
                #expect(receivedToken == token)
                return pingResult
            },
            launchAgentManager: launchAgentManager,
            probeServerProcess: { port in
                #expect(port == serverPort)
                return serverProcess
            },
            touchOnboardedSentinel: { }
        )
    }

    @Test("state tone follows state changes")
    func stateToneFollowsStateChanges() {
        var snapshot = ServerStatusSnapshot(state: .checking)
        #expect(snapshot.state.tone == .attention)

        snapshot.state = .running(version: "0.5.0", port: 9847)
        #expect(snapshot.state.tone == .running)

        snapshot.state = .failed(reason: "unreachable")
        #expect(snapshot.state.tone == .failed)
    }

    @Test("running: ping succeeds, snapshot is .running with version + port")
    func runningSnapshot() async throws {
        let setup = Self.makeSetup(
            token: "abc123",
            pingResult: .success(ServerPingInfo(version: "0.5.0")),
            tailscaleFromSettings: "100.64.0.1",
            serverPort: 19047
        )
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.state.tone == .running)
        #expect(snapshot.state == .running(version: "0.5.0", port: 19047))
        #expect(snapshot.tailscaleIP == "100.64.0.1")
        #expect(snapshot.processID == 16027)
        #expect(snapshot.uptime == "01:07:42")
        #expect(snapshot.isDevServerActive == false)
    }

    @Test("running: tron dev takeover uses the port owner for PID/uptime and marks dev mode")
    func devTakeoverRuntimeSnapshot() async throws {
        let setup = Self.makeSetup(
            token: "abc123",
            pingResult: .success(ServerPingInfo(version: "0.5.0")),
            tailscaleFromSettings: "100.64.0.1",
            serverProcess: ServerProcessInfo(
                pid: 24680,
                uptime: "00:00:09",
                isDevServer: true
            )
        )
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.state == .running(version: "0.5.0", port: 9847))
        #expect(snapshot.processID == 24680)
        #expect(snapshot.uptime == "00:00:09")
        #expect(snapshot.isDevServerActive == true)
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

    @Test("uses cached profile TOML Tailscale IP when server doesn't report one")
    func cachedTailscaleFromSettings() async throws {
        let setup = Self.makeSetup(
            token: "abc",
            pingResult: .success(ServerPingInfo(version: "0.5.0")),
            tailscaleFromSettings: "100.99.99.99"
        )
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.tailscaleIP == "100.99.99.99")
    }
}
