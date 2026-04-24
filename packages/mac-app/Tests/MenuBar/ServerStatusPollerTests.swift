import Foundation
import Testing
@testable import TronMac

@Suite("ServerStatusPoller — singleSnapshot")
struct ServerStatusPollerTests {
    static func makeSetup(
        token: String? = nil,
        pingResult: ServerPingResult = .unreachable,
        tailscaleFromSettings: String? = nil
    ) -> EnvironmentSetup {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return EnvironmentSetup(
            tronHome: tmp,
            installedBundle: tmp,
            installedBinary: tmp,
            bearerTokenPath: tmp,
            onboardedMarkerPath: tmp,
            settingsPath: tmp,
            launchAgentPlistPath: tmp,
            serverPort: 9847,
            onboardedSentinelExists: { false },
            readBearerToken: { token },
            readTailscaleIPFromSettings: { tailscaleFromSettings },
            probeTailscale: { .notInstalled },
            probePermission: { _ in .notDetermined },
            probeAgentPermissions: { [:] },
            detectExistingInstall: { .none },
            pingServer: { _ in pingResult },
            launchAgentManager: MockLaunchAgentManager(),
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
        #expect(snapshot.version == "0.5.0")
        #expect(snapshot.port == 9847)
        #expect(snapshot.tailscaleIP == "100.64.0.1")
        #expect(snapshot.bearerToken == "abc123")
    }

    @Test("unreachable + no token: stopped")
    func stoppedSnapshotNoToken() async throws {
        let setup = Self.makeSetup(token: nil, pingResult: .unreachable)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.tone == .stopped)
        #expect(snapshot.version == nil)
        #expect(snapshot.bearerToken == nil)
    }

    @Test("unreachable + token present: still stopped (server is down)")
    func stoppedSnapshotWithToken() async throws {
        let setup = Self.makeSetup(token: "abc123", pingResult: .unreachable)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.tone == .stopped)
        #expect(snapshot.bearerToken == "abc123")
    }

    @Test("timeout maps to stopped")
    func timeoutSnapshot() async throws {
        let setup = Self.makeSetup(token: "abc123", pingResult: .timeout)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.tone == .stopped)
    }

    @Test("explicit unauthorized → unauthorized regardless of token presence")
    func unauthorizedSnapshot() async throws {
        let setup = Self.makeSetup(token: "abc123", pingResult: .unauthorized)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.tone == .unauthorized)
        #expect(snapshot.bearerToken == "abc123")
    }

    @Test("malformed response: server is up but garbled — unknown")
    func malformedSnapshot() async throws {
        let setup = Self.makeSetup(token: "abc", pingResult: .malformedResponse)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.tone == .unknown)
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
