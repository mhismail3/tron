import Foundation
import Testing
@testable import TronMac

@Suite("MenuBarItemBuilder")
struct MenuBarItemBuilderTests {
    /// Supplies only the immutable inputs consumed by the pure builder.
    static func build(
        snapshot: ServerStatusSnapshot,
        tronHome: URL = URL(fileURLWithPath: "/tmp/tron", isDirectory: true),
        defaultServerPort: Int = 9847,
        canManageLaunchAgent: Bool = true
    ) -> [MenuItemDescriptor] {
        MenuBarItemBuilder.build(
            snapshot: snapshot,
            tronHome: tronHome,
            defaultServerPort: defaultServerPort,
            canManageLaunchAgent: canManageLaunchAgent
        )
    }

    @Test("paused snapshot: header reads paused and falls back when Tailscale is missing")
    func pausedSnapshot() throws {
        let snap = ServerStatusSnapshot(state: .paused)
        let items = Self.build(snapshot: snap)

        if case .header(let content) = items[0] {
            #expect(content.status == "Paused")
            #expect(content.endpoint == "Tailscale unavailable")
            #expect(content.hasEndpoint == false)
            #expect(content.tone == .paused)
        } else {
            Issue.record("first item should be header")
        }
    }

    @Test("running snapshot: header reads running with endpoint")
    func runningSnapshot() throws {
        let snap = ServerStatusSnapshot(
            state: .running(version: "0.5.0", port: 9847),
            tailscaleIP: "100.64.0.1",
            processID: 16027,
            uptime: "01:07:42"
        )
        let items = Self.build(snapshot: snap, defaultServerPort: 9848)

        if case .header(let content) = items[0] {
            #expect(content.status == "Running")
            #expect(content.endpoint == "100.64.0.1:9847")
            #expect(content.hasEndpoint == true)
            #expect(content.tone == .running)
            #expect(content.pid == 16027)
            #expect(content.uptime == "01:07:42")
            #expect(content.modeDetail == nil)
        } else {
            Issue.record("status should live in custom header")
        }
    }

    @Test("dev snapshot: header calls out active dev server")
    func devSnapshotHeader() throws {
        let snap = ServerStatusSnapshot(
            state: .running(version: "0.5.0", port: 9847),
            tailscaleIP: "100.64.0.1",
            processID: 24680,
            uptime: "00:00:09",
            isDevServerActive: true
        )
        let items = Self.build(snapshot: snap)

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
        let snap = ServerStatusSnapshot(
            state: .running(version: "0.5.0", port: 9847),
            isDevServerActive: true
        )
        let items = Self.build(snapshot: snap)
        let titles = items.map(\.title)

        #expect(titles == [
            "Tron",
            "—",
            "Show pairing info",
            "Open Tron folder",
            "Show logs",
            "Send feedback",
            "Stop Mac Operator",
            "—",
            "Pause server",
            "Restart server",
            "Stop dev server",
            "Uninstall Tron",
            "Quit Tron",
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

    @Test("dev snapshot: stop dev appears with server controls")
    func stopDevAppearsWithServerControlsDuringTakeover() throws {
        let snap = ServerStatusSnapshot(
            state: .running(version: "0.5.0", port: 9847),
            isDevServerActive: true
        )
        let titles = Self.build(snapshot: snap).map(\.title)

        #expect(Array(titles.suffix(5)) == [
            "Pause server",
            "Restart server",
            "Stop dev server",
            "Uninstall Tron",
            "Quit Tron",
        ])
    }

    @Test("running snapshot includes Pause server (not Resume)")
    func pauseShownWhileRunning() throws {
        let snap = ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847))
        let items = Self.build(snapshot: snap)

        let titles = items.map(\.title)
        #expect(titles.contains("Pause server"))
        #expect(!titles.contains("Resume server"))
    }

    @Test("paused snapshot includes Resume server (not Pause)")
    func resumeShownWhilePaused() throws {
        let snap = ServerStatusSnapshot(state: .paused)
        let items = Self.build(snapshot: snap)

        let titles = items.map(\.title)
        #expect(titles.contains("Resume server"))
        #expect(!titles.contains("Pause server"))
    }

    @Test("menu always has pairing, folder, logs, feedback, server controls, uninstall, quit")
    func canonicalActionPresence() throws {
        let snap = ServerStatusSnapshot.checking
        let items = Self.build(snapshot: snap)

        let titles = Set(items.map(\.title))
        for required in [
            "Show pairing info",
            "Restart server",
            "Show logs",
            "Open Tron folder",
            "Send feedback",
            "Stop Mac Operator",
            "Uninstall Tron",
            "Quit Tron",
        ] {
            #expect(titles.contains(required), "missing \(required) in menu")
        }
        #expect(!titles.contains("Show Developer Options"))
        #expect(!titles.contains("Start dev server"))
    }

    @Test("menu sections use the canonical order")
    func canonicalSectionOrder() throws {
        let snap = ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847))
        let titles = Self.build(snapshot: snap).map(\.title)

        #expect(titles == [
            "Tron",
            "—",
            "Show pairing info",
            "Open Tron folder",
            "Show logs",
            "Send feedback",
            "Stop Mac Operator",
            "—",
            "Pause server",
            "Restart server",
            "Uninstall Tron",
            "Quit Tron",
        ])
    }

    @Test("menu titles map directly to typed actions")
    func canonicalActionRouting() throws {
        let snap = ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847))
        let actions = Dictionary(uniqueKeysWithValues: Self.build(snapshot: snap).compactMap { item in
            if case .action(let title, _, let action) = item {
                return (title, action)
            }
            return nil
        })

        #expect(actions == [
            "Show pairing info": .showPairingInfo,
            "Show logs": .viewLogs,
            "Send feedback": .sendFeedback,
            "Stop Mac Operator": .stopMacOperator,
            "Pause server": .pauseServer,
            "Restart server": .restartServer,
            "Uninstall Tron": .uninstall,
        ])

        let pausedItems = Self.build(snapshot: ServerStatusSnapshot(state: .paused))
        #expect(pausedItems.contains(.action(title: "Resume server", isEnabled: true, action: .resumeServer)))

        let devSnapshot = ServerStatusSnapshot(
            state: .running(version: "0.5.0", port: 9847),
            isDevServerActive: true
        )
        let devItems = Self.build(snapshot: devSnapshot)
        #expect(devItems.contains(.action(title: "Stop dev server", isEnabled: true, action: .stopDevServer)))

        let stoppedItems = MenuBarItemBuilder.build(
            snapshot: snap,
            tronHome: URL(fileURLWithPath: "/tmp/tron", isDirectory: true),
            defaultServerPort: 9847,
            canManageLaunchAgent: true,
            macOperatorStopped: true
        )
        #expect(stoppedItems.contains(.action(
            title: "Resume Mac Operator",
            isEnabled: true,
            action: .resumeMacOperator
        )))
    }

    @Test("debug companion disables production LaunchAgent controls")
    func companionDisablesProductionControls() throws {
        let snap = ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847))
        let items = Self.build(snapshot: snap, canManageLaunchAgent: false)

        for item in items {
            if case .action(let title, let isEnabled, _) = item,
               ["Pause server", "Restart server", "Uninstall Tron"].contains(title) {
                #expect(!isEnabled, "\(title) should be disabled in companion mode")
            }
        }
    }

    @Test("menu omits developer start commands")
    func menuOmitsDeveloperStartCommands() throws {
        let snap = ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847))
        let items = Self.build(snapshot: snap)
        let titles = items.map(\.title)

        #expect(!titles.contains("Show Developer Options"))
        #expect(!titles.contains("Hide Developer Options"))
        #expect(!titles.contains("Start dev server"))
        #expect(!titles.contains("Start dev server after tests"))
        #expect(!titles.contains("Build, test, and start dev server"))
        #expect(!titles.contains("Open dev command log"))
        #expect(!titles.contains("Stop dev server"))
    }

    @Test("busy snapshot disables server controls and shows transient action title")
    func busyDisablesServerControls() throws {
        let snap = ServerStatusSnapshot(state: .busy(.restarting))
        let items = Self.build(snapshot: snap)

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
        let snap = ServerStatusSnapshot(state: .failed(reason: "timeout"))
        let items = Self.build(snapshot: snap)
        if case .header(let content) = items[0] {
            #expect(content.status == "Stopped")
            #expect(content.tone == .failed)
        } else {
            Issue.record("first item should be header")
        }
    }

    @Test("status title flips for unauthorized state")
    func unauthorizedTitle() throws {
        let snap = ServerStatusSnapshot(state: .unauthorized)
        let items = Self.build(snapshot: snap)
        if case .header(let content) = items[0] {
            #expect(content.status == "Needs token")
            #expect(content.tone == .attention)
        } else {
            Issue.record("first item should be header")
        }
    }

    @Test("status title 'checking' for checking state")
    func checkingTitle() throws {
        let snap = ServerStatusSnapshot.checking
        let items = Self.build(snapshot: snap)
        if case .header(let content) = items[0] {
            #expect(content.status == "Checking")
            #expect(content.tone == .attention)
        } else {
            Issue.record("first item should be header")
        }
    }

    @Test("Open Tron folder uses the configured tronHome path")
    func openFolderUsesPath() throws {
        let tronHome = URL(fileURLWithPath: "/tmp/custom-tron", isDirectory: true)
        let snap = ServerStatusSnapshot.checking
        let items = Self.build(snapshot: snap, tronHome: tronHome)
        let openLink = items.first { item in
            if case .openLink(_, _) = item { return true } else { return false }
        }
        guard case .openLink(_, let url) = openLink else {
            Issue.record("expected an openLink for Open Tron folder")
            return
        }
        #expect(url == tronHome)
    }

    @Test("uptime formatter accepts ps elapsed-time formats and rejects malformed values")
    func uptimeFormatter() {
        #expect(MenuBarUptimeFormatter.parse("07:42") == 462)
        #expect(MenuBarUptimeFormatter.parse("01:07:42") == 4_062)
        #expect(MenuBarUptimeFormatter.parse("2-01:07:42") == 176_862)
        #expect(MenuBarUptimeFormatter.parse("1:bad") == nil)
        #expect(MenuBarUptimeFormatter.parse("1::02") == nil)
        #expect(MenuBarUptimeFormatter.display("07:42") == "00:07:42")
        #expect(MenuBarUptimeFormatter.display("10:48") == "00:10:48")
        #expect(MenuBarUptimeFormatter.display("2-01:07:42") == "2-01:07:42")
        #expect(MenuBarUptimeFormatter.display("unknown") == "unknown")
        #expect(MenuBarUptimeFormatter.format(4_062) == "01:07:42")
        #expect(MenuBarUptimeFormatter.format(176_862) == "2-01:07:42")
    }
}
