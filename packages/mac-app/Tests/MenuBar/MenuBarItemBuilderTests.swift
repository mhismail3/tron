import Foundation
import Testing
@testable import TronMac

@Suite("MenuBarItemBuilder")
struct MenuBarItemBuilderTests {
    /// Returns a synthetic EnvironmentSetup pointing at a throwaway tmp
    /// directory. We only consume `serverPort` and `tronHome` from the
    /// builder, so all the closures can be stub `{ _ in nil }`.
    static func makeSetup(
        in tmp: URL,
        port: Int = 9847,
        canManageLaunchAgent: Bool = true
    ) -> EnvironmentSetup {
        EnvironmentSetup(
            tronHome: tmp,
            applicationBundle: tmp.appendingPathComponent("Tron.app"),
            serverHelperBundle: tmp.appendingPathComponent("Tron.app/Contents/Library/LoginItems/Tron Server.app"),
            serverHelperBinary: tmp.appendingPathComponent("Tron.app/Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron"),
            bearerTokenPath: tmp.appendingPathComponent("auth.json"),
            onboardedMarkerPath: tmp.appendingPathComponent("run/.onboarded"),
            settingsPath: tmp.appendingPathComponent("settings.json"),
            launchAgentPlistPath: tmp.appendingPathComponent("com.tron.server.plist"),
            launchAgentLabel: "com.tron.server",
            serverPort: port,
            canManageLaunchAgent: canManageLaunchAgent,
            wrapperLockPath: tmp.appendingPathComponent("run/.mac-wrapper.com.tron.mac.lock"),
            onboardedSentinelExists: { false },
            readBearerToken: { nil },
            readTailscaleIPFromSettings: { nil },
            cacheTailscaleIP: { _ in },
            probeTailscale: { .notInstalled },
            probePermissions: { [:] },
            detectExistingInstall: { .none },
            validateApplicationLocation: { nil },
            validateBundledHelper: { nil },
            pingServer: { _ in .unreachable },
            launchAgentManager: MockLaunchAgentManager(),
            applyTranscriptionPreference: { _ in .disabled },
            touchOnboardedSentinel: { }
        )
    }

    @Test("paused snapshot: header reads paused, omits token, and falls back when Tailscale is missing")
    func pausedSnapshot() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)

        let snap = ServerStatusSnapshot(state: .paused)
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)

        if case .header(let content) = items[0] {
            #expect(content.status == "Paused")
            #expect(content.endpoint == "Tailscale unavailable")
            #expect(content.hasEndpoint == false)
            #expect(content.health == .paused)
        } else {
            Issue.record("first item should be header")
        }
        #expect(!items.map(\.title).contains { $0.contains("Pairing token") })
    }

    @Test("running snapshot: header reads running with endpoint")
    func runningSnapshot() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(
            state: .running(version: "0.5.0", port: 9847),
            tailscaleIP: "100.64.0.1",
            bearerToken: "abcd1234efgh5678",
            processID: 16027,
            uptime: "01:07:42"
        )
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)

        if case .header(let content) = items[0] {
            #expect(content.status == "Running")
            #expect(content.endpoint == "100.64.0.1:9847")
            #expect(content.hasEndpoint == true)
            #expect(content.health == .healthy)
            #expect(content.pid == 16027)
            #expect(content.uptime == "01:07:42")
            #expect(content.modeDetail == nil)
        } else {
            Issue.record("status should live in custom header")
        }
        #expect(!items.map(\.title).contains { $0.contains("Pairing token") })
    }

    @Test("dev snapshot: header calls out active dev server")
    func devSnapshotHeader() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(
            state: .running(version: "0.5.0", port: 9847),
            tailscaleIP: "100.64.0.1",
            processID: 24680,
            uptime: "00:00:09",
            isDevServerActive: true
        )
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)

        if case .header(let content) = items[0] {
            #expect(content.status == "Running")
            #expect(content.pid == 24680)
            #expect(content.uptime == "00:00:09")
            #expect(content.modeDetail == "Dev Server active")
        } else {
            Issue.record("status should live in custom header")
        }
    }

    @Test("dev snapshot: stop dev action appears and service controls are disabled")
    func devSnapshotControls() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(
            state: .running(version: "0.5.0", port: 9847),
            isDevServerActive: true
        )
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)
        let titles = items.map(\.title)

        #expect(titles == [
            "Tron",
            "—",
            "Show pairing info",
            "Open Tron folder",
            "Show logs",
            "Check for updates",
            "Send feedback",
            "—",
            "Pause server",
            "Restart server",
            "Uninstall Tron",
            "Quit Tron",
            "—",
            "Open dev command log",
            "Stop dev server",
            "Show Developer Options",
        ])

        for item in items {
            if case .action(let title, let isEnabled, _) = item {
                if title == "Stop dev server" {
                    #expect(isEnabled == true)
                }
                if ["Pause server", "Restart server", "Uninstall Tron"].contains(title) {
                    #expect(isEnabled == false, "\(title) should be disabled while dev owns port 9847")
                }
            }
        }
    }

    @Test("dev snapshot: collapsed developer section still shows stop dev")
    func collapsedDeveloperSectionShowsStopDevDuringTakeover() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(
            state: .running(version: "0.5.0", port: 9847),
            isDevServerActive: true
        )
        let titles = MenuBarItemBuilder.build(snapshot: snap, paths: setup).map(\.title)

        #expect(Array(titles.suffix(4)) == [
            "—",
            "Open dev command log",
            "Stop dev server",
            "Show Developer Options",
        ])
    }

    @Test("running snapshot includes Pause server (not Resume)")
    func pauseShownWhileRunning() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847))
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)

        let titles = items.map(\.title)
        #expect(titles.contains("Pause server"))
        #expect(!titles.contains("Resume server"))
    }

    @Test("paused snapshot includes Resume server (not Pause)")
    func resumeShownWhilePaused() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(state: .paused)
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)

        let titles = items.map(\.title)
        #expect(titles.contains("Resume server"))
        #expect(!titles.contains("Pause server"))
    }

    @Test("menu always has pairing, folder, logs, updates, feedback, server controls, uninstall, quit")
    func canonicalActionPresence() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot.checking
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)

        let titles = Set(items.map(\.title))
        for required in [
            "Show pairing info",
            "Restart server",
            "Show logs",
            "Open Tron folder",
            "Send feedback",
            "Check for updates",
            "Uninstall Tron",
            "Quit Tron",
            "Show Developer Options",
        ] {
            #expect(titles.contains(required), "missing \(required) in menu")
        }
    }

    @Test("menu sections use the canonical order")
    func canonicalSectionOrder() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847))
        let titles = MenuBarItemBuilder.build(snapshot: snap, paths: setup).map(\.title)

        #expect(titles == [
            "Tron",
            "—",
            "Show pairing info",
            "Open Tron folder",
            "Show logs",
            "Check for updates",
            "Send feedback",
            "—",
            "Pause server",
            "Restart server",
            "Uninstall Tron",
            "Quit Tron",
            "—",
            "Show Developer Options",
        ])
    }

    @Test("debug companion disables production LaunchAgent controls")
    func companionDisablesProductionControls() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp, canManageLaunchAgent: false)
        let snap = ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847))
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)

        for item in items {
            if case .action(let title, let isEnabled, _) = item,
               ["Pause server", "Restart server", "Uninstall Tron"].contains(title) {
                #expect(!isEnabled, "\(title) should be disabled in companion mode")
            }
        }
    }

    @Test("developer options are collapsed by default at the bottom")
    func developerOptionsCollapsedByDefault() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847))
        let titles = MenuBarItemBuilder.build(snapshot: snap, paths: setup).map(\.title)

        #expect(Array(titles.suffix(2)) == ["—", "Show Developer Options"])
        #expect(!titles.contains("Start dev server"))
        #expect(!titles.contains("Hide Developer Options"))
    }

    @Test("expanded developer options show dev commands above hide toggle")
    func developerOptionsExpanded() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847))
        let items = MenuBarItemBuilder.build(
            snapshot: snap,
            paths: setup,
            developerOptionsVisible: true
        )
        let titles = items.map(\.title)

        #expect(Array(titles.suffix(5)) == [
            "—",
            "Start dev server",
            "Start dev server after tests",
            "Build, test, and start dev server",
            "Hide Developer Options",
        ])

        for item in items {
            if case .action(let title, let isEnabled, _) = item,
               TronDevCommand.menuCommands.map(\.title).contains(title) {
                #expect(isEnabled)
            }
        }
    }

    @Test("expanded developer options disable start commands while dev is active")
    func developerOptionsDisableStartCommandsDuringTakeover() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(
            state: .running(version: "0.5.0", port: 9847),
            isDevServerActive: true
        )
        let items = MenuBarItemBuilder.build(
            snapshot: snap,
            paths: setup,
            developerOptionsVisible: true
        )
        let titles = items.map(\.title)

        #expect(Array(titles.suffix(7)) == [
            "—",
            "Open dev command log",
            "Stop dev server",
            "Start dev server",
            "Start dev server after tests",
            "Build, test, and start dev server",
            "Hide Developer Options",
        ])

        for item in items {
            if case .action(let title, let isEnabled, _) = item,
               TronDevCommand.menuCommands.map(\.title).contains(title) {
                #expect(!isEnabled, "\(title) should be disabled while dev owns port 9847")
            }
        }
        #expect(titles.last == "Hide Developer Options")
    }

    @Test("starting dev snapshot keeps busy status and exposes command log")
    func startingDevSnapshotShowsLog() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(state: .busy(.startingDevServer))
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)
        let titles = items.map(\.title)

        if case .header(let content) = items[0] {
            #expect(content.status == "Starting dev")
            #expect(content.health == .attention)
            #expect(content.modeDetail == "Dev command running")
        } else {
            Issue.record("first item should be header")
        }

        #expect(titles.contains("Open dev command log"))
        #expect(!titles.contains("Stop dev server"))

        let logItem = items.first { item in
            if case .openLink(let title, _) = item, title == "Open dev command log" {
                return true
            }
            return false
        }
        guard case .openLink(_, let url) = logItem else {
            Issue.record("expected Open dev command log link")
            return
        }
        #expect(url == tmp.appendingPathComponent("system/run/dev-menu-command.log", isDirectory: false))
    }

    @Test("busy snapshot disables server controls and shows transient action title")
    func busyDisablesServerControls() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(state: .busy(.restarting))
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)

        let titles = items.map(\.title)
        #expect(titles.contains("Restarting…"))

        for item in items {
            if case .action(let title, let isEnabled, _) = item,
               title == "Restarting…" {
                #expect(isEnabled == false)
            }
        }
    }

    @Test("failed status title carries reason")
    func failedTitle() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(state: .failed(reason: "timeout"))
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)
        if case .header(let content) = items[0] {
            #expect(content.status == "Stopped")
            #expect(content.health == .stopped)
        } else {
            Issue.record("first item should be header")
        }
    }

    @Test("status title flips for unauthorized state")
    func unauthorizedTitle() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(state: .unauthorized)
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)
        if case .header(let content) = items[0] {
            #expect(content.status == "Needs token")
            #expect(content.health == .attention)
        } else {
            Issue.record("first item should be header")
        }
    }

    @Test("status title 'checking' for checking state")
    func checkingTitle() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot.checking
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)
        if case .header(let content) = items[0] {
            #expect(content.status == "Checking")
            #expect(content.health == .attention)
        } else {
            Issue.record("first item should be header")
        }
    }

    @Test("pairing token never appears in menu descriptors")
    func pairingTokenStaysInPairingWindow() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847), bearerToken: "abc12345")
        let items = MenuBarItemBuilder.build(snapshot: snap, paths: setup)
        #expect(!items.contains { $0.title.contains("Pairing token") })
    }

    @Test("Open Tron folder uses the configured tronHome path")
    func openFolderUsesPath() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let setup = Self.makeSetup(in: tmp)
        let snap = ServerStatusSnapshot.checking
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

    @Test("uptime formatter accepts ps elapsed-time formats and rejects malformed values")
    func uptimeFormatter() {
        #expect(MenuBarUptimeFormatter.parse("07:42") == 462)
        #expect(MenuBarUptimeFormatter.parse("01:07:42") == 4_062)
        #expect(MenuBarUptimeFormatter.parse("2-01:07:42") == 176_862)
        #expect(MenuBarUptimeFormatter.parse("1:bad") == nil)
        #expect(MenuBarUptimeFormatter.parse("1::02") == nil)
        #expect(MenuBarUptimeFormatter.format(4_062) == "01:07:42")
        #expect(MenuBarUptimeFormatter.format(176_862) == "2-01:07:42")
    }
}
