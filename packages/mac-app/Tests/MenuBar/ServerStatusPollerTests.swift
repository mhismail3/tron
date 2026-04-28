import Foundation
import Testing
@testable import TronMac

@Suite("ServerStatusPoller — singleSnapshot")
struct ServerStatusPollerTests {
    static func makeSetup(
        token: String? = nil,
        pingResult: ServerPingResult = .unreachable,
        tailscaleFromSettings: String? = nil,
        launchAgentLoaded: Bool = false
    ) -> EnvironmentSetup {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let launchAgentManager = MockLaunchAgentManager()
        launchAgentManager.loaded = launchAgentLoaded
        launchAgentManager.runtimeInfo = LaunchAgentRuntimeInfo(pid: 16027, uptime: "01:07:42")
        return EnvironmentSetup(
            tronHome: tmp,
            applicationBundle: tmp,
            serverHelperBundle: tmp.appendingPathComponent("Tron Server.app"),
            serverHelperBinary: tmp.appendingPathComponent("Tron Server.app/Contents/MacOS/tron"),
            bearerTokenPath: tmp,
            onboardedMarkerPath: tmp,
            settingsPath: tmp,
            launchAgentPlistPath: tmp,
            serverPort: 9847,
            onboardedSentinelExists: { false },
            readBearerToken: { token },
            readTailscaleIPFromSettings: { tailscaleFromSettings },
            cacheTailscaleIP: { _ in },
            probeTailscale: { .notInstalled },
            probePermissions: { [:] },
            detectExistingInstall: { .none },
            validateApplicationLocation: { nil },
            validateBundledHelper: { nil },
            pingServer: { _ in pingResult },
            launchAgentManager: launchAgentManager,
            applyTranscriptionPreference: { _ in .disabled },
            touchOnboardedSentinel: { }
        )
    }

    @Test("running: ping succeeds, snapshot is .running with version + port")
    func runningSnapshot() async throws {
        let setup = Self.makeSetup(
            token: "abc123",
            pingResult: .success(ServerInfo(version: "0.5.0", port: 9847, tailscaleIp: "100.64.0.1", paired: true))
        )
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.tone == .running)
        #expect(snapshot.state == .running(version: "0.5.0", port: 9847))
        #expect(snapshot.version == "0.5.0")
        #expect(snapshot.port == 9847)
        #expect(snapshot.tailscaleIP == "100.64.0.1")
        #expect(snapshot.bearerToken == "abc123")
        #expect(snapshot.processID == 16027)
        #expect(snapshot.uptime == "01:07:42")
    }

    @Test("unreachable + launchd unloaded: paused")
    func pausedSnapshotWhenLaunchdUnloaded() async throws {
        let setup = Self.makeSetup(token: nil, pingResult: .unreachable)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.state == .paused)
        #expect(snapshot.tone == .paused)
        #expect(snapshot.version == nil)
        #expect(snapshot.bearerToken == nil)
    }

    @Test("unreachable + launchd loaded: failed")
    func failedSnapshotWhenLaunchdLoaded() async throws {
        let setup = Self.makeSetup(token: "abc123", pingResult: .unreachable, launchAgentLoaded: true)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.state == .failed(reason: "unreachable"))
        #expect(snapshot.tone == .failed)
        #expect(snapshot.bearerToken == "abc123")
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
        #expect(snapshot.tone == .attention)
        #expect(snapshot.bearerToken == "abc123")
    }

    @Test("malformed response + launchd loaded maps to failed")
    func malformedSnapshot() async throws {
        let setup = Self.makeSetup(token: "abc", pingResult: .malformedResponse, launchAgentLoaded: true)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.state == .failed(reason: "malformed response"))
    }

    @Test("falls back to settings.json tailscale IP when server doesn't report one")
    func fallbackTailscaleFromSettings() async throws {
        let setup = Self.makeSetup(
            token: "abc",
            pingResult: .success(ServerInfo(version: "0.5.0", port: 9847, tailscaleIp: nil, paired: false)),
            tailscaleFromSettings: "100.99.99.99"
        )
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.tailscaleIP == "100.99.99.99")
    }
}
