import Foundation
import Testing
@testable import TronMac

@Suite("ServerStatusPoller — singleSnapshot")
struct ServerStatusPollerTests {
    static func makeSetup(
        token: String? = nil,
        info: ServerInfo? = nil,
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
            detectExistingInstall: { .none },
            pingServer: { _ in info },
            launchAgentManager: MockLaunchAgentManager(),
            touchOnboardedSentinel: { }
        )
    }

    @Test("running: ping returns info, snapshot is .running with version + port")
    func runningSnapshot() async throws {
        let setup = Self.makeSetup(
            token: "abc123",
            info: ServerInfo(version: "0.5.0", port: 9847, tailscaleIp: "100.64.0.1", paired: true)
        )
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.tone == .running)
        #expect(snapshot.version == "0.5.0")
        #expect(snapshot.port == 9847)
        #expect(snapshot.tailscaleIP == "100.64.0.1")
        #expect(snapshot.bearerToken == "abc123")
    }

    @Test("ping returns nil + no token: stopped")
    func stoppedSnapshot() async throws {
        let setup = Self.makeSetup(token: nil, info: nil)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.tone == .stopped)
        #expect(snapshot.version == nil)
        #expect(snapshot.bearerToken == nil)
    }

    @Test("ping returns nil + token present: unauthorized")
    func unauthorizedSnapshot() async throws {
        let setup = Self.makeSetup(token: "abc123", info: nil)
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.tone == .unauthorized)
        #expect(snapshot.bearerToken == "abc123")
    }

    @Test("falls back to settings.json tailscale IP when server doesn't report one")
    func fallbackTailscaleFromSettings() async throws {
        let setup = Self.makeSetup(
            token: "abc",
            info: ServerInfo(version: "0.5.0", port: 9847, tailscaleIp: nil, paired: false),
            tailscaleFromSettings: "100.99.99.99"
        )
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        #expect(snapshot.tailscaleIP == "100.99.99.99")
    }
}
