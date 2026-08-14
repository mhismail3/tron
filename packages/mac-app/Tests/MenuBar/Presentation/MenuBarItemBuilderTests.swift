import Foundation
import Testing
@testable import TronMac

@Suite("MenuBarItemBuilder")
struct MenuBarItemBuilderTests {
    /// Supplies only the immutable inputs consumed by the pure builder.
    static func build(
        snapshot: GatewayStatusSnapshot,
        tronHome: URL = URL(fileURLWithPath: "/tmp/tron", isDirectory: true),
        defaultGatewayPort: Int = 9847
    ) -> [MenuItemDescriptor] {
        MenuBarItemBuilder.build(
            snapshot: snapshot,
            tronHome: tronHome,
            defaultGatewayPort: defaultGatewayPort
        )
    }

    @Test("paused snapshot: header reads paused and falls back when Tailscale is missing")
    func pausedSnapshot() throws {
        let snap = GatewayStatusSnapshot(state: .paused)
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
        let snap = GatewayStatusSnapshot(
            state: .running(version: "0.5.0", port: 9847),
            tailscaleIP: "100.64.0.1",
            processID: 16027,
            uptime: "01:07:42"
        )
        let items = Self.build(snapshot: snap, defaultGatewayPort: 9848)

        if case .header(let content) = items[0] {
            #expect(content.status == "Running")
            #expect(content.endpoint == "100.64.0.1:9847")
            #expect(content.hasEndpoint == true)
            #expect(content.tone == .running)
            #expect(content.pid == 16027)
            #expect(content.uptime == "01:07:42")
        } else {
            Issue.record("status should live in custom header")
        }
    }

    @Test("running snapshot includes Pause Tron (not Resume)")
    func pauseShownWhileRunning() throws {
        let snap = GatewayStatusSnapshot(state: .running(version: "0.5.0", port: 9847))
        let items = Self.build(snapshot: snap)

        let titles = items.map(\.title)
        #expect(titles.contains("Pause Tron"))
        #expect(!titles.contains("Resume Tron"))
    }

    @Test("paused snapshot includes Resume Tron (not Pause)")
    func resumeShownWhilePaused() throws {
        let snap = GatewayStatusSnapshot(state: .paused)
        let items = Self.build(snapshot: snap)

        let titles = items.map(\.title)
        #expect(titles.contains("Resume Tron"))
        #expect(!titles.contains("Pause Tron"))
    }

    @Test("menu always has pairing, folder, logs, feedback, Gateway controls, uninstall, quit")
    func canonicalActionPresence() throws {
        let snap = GatewayStatusSnapshot.checking
        let items = Self.build(snapshot: snap)

        let titles = Set(items.map(\.title))
        for required in [
            "Show pairing info",
            "Restart Tron",
            "Show logs",
            "Open Tron folder",
            "Send feedback",
            "Uninstall Tron",
            "Quit Tron",
        ] {
            #expect(titles.contains(required), "missing \(required) in menu")
        }
    }

    @Test("menu sections use the canonical order")
    func canonicalSectionOrder() throws {
        let snap = GatewayStatusSnapshot(state: .running(version: "0.5.0", port: 9847))
        let titles = Self.build(snapshot: snap).map(\.title)

        #expect(titles == [
            "Tron",
            "—",
            "Show pairing info",
            "Open Tron folder",
            "Show logs",
            "Send feedback",
            "—",
            "Pause Tron",
            "Restart Tron",
            "Uninstall Tron",
            "Quit Tron",
        ])
    }

    @Test("menu titles map directly to typed actions")
    func canonicalActionRouting() throws {
        let snap = GatewayStatusSnapshot(state: .running(version: "0.5.0", port: 9847))
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
            "Pause Tron": .pauseGateway,
            "Restart Tron": .restartGateway,
            "Uninstall Tron": .uninstall,
        ])

        let pausedItems = Self.build(snapshot: GatewayStatusSnapshot(state: .paused))
        #expect(pausedItems.contains(.action(title: "Resume Tron", isEnabled: true, action: .resumeGateway)))


    }

    @Test("busy snapshot disables Gateway controls and shows transient action title")
    func busyDisablesGatewayControls() throws {
        let snap = GatewayStatusSnapshot(state: .busy(.restarting))
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
        let snap = GatewayStatusSnapshot(state: .failed(reason: "timeout"))
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
        let snap = GatewayStatusSnapshot(state: .unauthorized)
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
        let snap = GatewayStatusSnapshot.checking
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
        let snap = GatewayStatusSnapshot.checking
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
