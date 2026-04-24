import Foundation
import Testing
@testable import TronMac

@Suite("MenuBarItemBuilder")
struct MenuBarItemBuilderTests {
    /// Returns a synthetic EnvironmentSetup pointing at a throwaway tmp
    /// directory. We only consume `serverPort` and `tronHome` from the
    /// builder, so all the closures can be stub `{ _ in nil }`.
    static func makeSetup(in tmp: URL, port: Int = 9847) -> EnvironmentSetup {
        EnvironmentSetup(
            tronHome: tmp,
            installedBundle: tmp.appendingPathComponent("Tron.app"),
            installedBinary: tmp.appendingPathComponent("Tron.app/Contents/MacOS/tron"),
            bearerTokenPath: tmp.appendingPathComponent("auth-token.json"),
            onboardedMarkerPath: tmp.appendingPathComponent(".onboarded"),
            settingsPath: tmp.appendingPathComponent("settings.json"),
            launchAgentPlistPath: tmp.appendingPathComponent("com.tron.server.plist"),
            serverPort: port,
            onboardedSentinelExists: { false },
            readBearerToken: { nil },
            readTailscaleIPFromSettings: { nil },
            probeTailscale: { .notInstalled },
            probePermission: { _ in .notDetermined },
            probeAgentPermissions: { [:] },
            detectExistingInstall: { .none },
            pingServer: { _ in .unreachable },
            launchAgentManager: MockLaunchAgentManager(),
            touchOnboardedSentinel: { }
        )
    }

    @Test("stopped snapshot: status row reads stopped, no token + Tailscale rows fall back")
    func stoppedSnapshot() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)

        let snap = ServerStatusSnapshot(tone: .stopped, version: nil, port: nil, tailscaleIP: nil, bearerToken: nil)
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)

        // Status row is always first.
        if case .text(let title) = items[0] {
            #expect(title == "Tron — stopped")
        } else {
            Issue.record("first item should be .text status row")
        }

        // Tailscale row has fallback text.
        if case .text(let title) = items[1] {
            #expect(title == "Tailscale: not available")
        } else {
            Issue.record("second item should be Tailscale text")
        }

        // Token row has fallback text.
        if case .text(let title) = items[2] {
            #expect(title == "Pairing token: (not generated)")
        } else {
            Issue.record("third item should be token text")
        }
    }

    @Test("running snapshot: status row reads running with port + version")
    func runningSnapshot() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(
            tone: .running,
            version: "0.5.0",
            port: 9847,
            tailscaleIP: "100.64.0.1",
            bearerToken: "abcd1234efgh5678"
        )
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)

        if case .text(let title) = items[0] {
            #expect(title == "Tron — running on port 9847 (v0.5.0)")
        } else {
            Issue.record("status row should be .text")
        }

        if case .copy(let title, let value) = items[1] {
            #expect(title == "Tailscale: 100.64.0.1:9847")
            #expect(value == "100.64.0.1:9847")
        } else {
            Issue.record("expected copy row for tailscale")
        }

        if case .copy(let title, let value) = items[2] {
            #expect(title == "Pairing token: abcd…5678")
            #expect(value == "abcd1234efgh5678")
        } else {
            Issue.record("expected copy row for token")
        }
    }

    @Test("running snapshot includes Pause server (not Resume)")
    func pauseShownWhileRunning() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(tone: .running, version: "0.5.0", port: 9847, tailscaleIP: nil, bearerToken: nil)
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)

        let titles = items.map(\.title)
        #expect(titles.contains("Pause server"))
        #expect(!titles.contains("Resume server"))
    }

    @Test("stopped snapshot includes Resume server (not Pause)")
    func resumeShownWhileStopped() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(tone: .stopped, version: nil, port: nil, tailscaleIP: nil, bearerToken: nil)
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)

        let titles = items.map(\.title)
        #expect(titles.contains("Resume server"))
        #expect(!titles.contains("Pause server"))
    }

    @Test("menu always has Restart, Logs, Open folder, Feedback, Updates, Uninstall, Quit")
    func canonicalActionPresence() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(tone: .unknown, version: nil, port: nil, tailscaleIP: nil, bearerToken: nil)
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)

        let titles = Set(items.map(\.title))
        for required in [
            "Show pairing info…",
            "Restart server",
            "View logs…",
            "Open Tron folder",
            "Send feedback…",
            "Check for updates…",
            "Uninstall Tron…",
            "Quit Tron",
        ] {
            #expect(titles.contains(required), "missing \(required) in menu")
        }
    }

    @Test("status title flips for unauthorized tone")
    func unauthorizedTitle() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(tone: .unauthorized, version: nil, port: nil, tailscaleIP: nil, bearerToken: nil)
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)
        if case .text(let title) = items[0] {
            #expect(title == "Tron — token missing or rejected")
        } else {
            Issue.record("first item should be status row")
        }
    }

    @Test("status title 'checking' for unknown tone")
    func unknownTitle() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot.unknown
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)
        if case .text(let title) = items[0] {
            #expect(title == "Tron — checking…")
        } else {
            Issue.record("first item should be status row")
        }
    }

    @Test("short token (<=9 chars) is not truncated")
    func shortTokenNoTruncation() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(tone: .running, version: "0.5.0", port: 9847, tailscaleIP: nil, bearerToken: "abc12345")
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)
        if case .copy(let title, _) = items[2] {
            #expect(title == "Pairing token: abc12345", "tokens <= 9 chars stay literal")
        } else {
            Issue.record("third item should be token row")
        }
    }

    @Test("Open Tron folder uses the configured tronHome path")
    func openFolderUsesPath() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot.unknown
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)
        let openLink = items.first { item in
            if case .openLink(_, _) = item { return true } else { return false }
        }
        guard case .openLink(_, let url) = openLink else {
            Issue.record("expected an openLink for Open Tron folder")
            return
        }
        #expect(url == tmp)
    }
}
