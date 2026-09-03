import Foundation
import Testing
@testable import TronMac

@Suite("MenuBarItemBuilder")
struct MenuBarItemBuilderTests {
    static func build(
        snapshot: ServerStatusSnapshot,
        tronHome: URL = URL(fileURLWithPath: "/tmp/tron", isDirectory: true),
        defaultServerPort: Int = 9847,
        canManageLaunchAgent: Bool = true,
        debugGateway: DebugGatewayMenuState = .unavailable
    ) -> [MenuItemDescriptor] {
        MenuBarItemBuilder.build(
            snapshot: snapshot,
            tronHome: tronHome,
            defaultServerPort: defaultServerPort,
            canManageLaunchAgent: canManageLaunchAgent,
            debugGateway: debugGateway
        )
    }

    @Test("running snapshot preserves endpoint and process diagnostics")
    func runningSnapshot() {
        let snap = ServerStatusSnapshot(
            state: .running(version: "0.5.0", port: 9847),
            tailscaleIP: "100.64.0.1",
            processID: 16027,
            uptime: "01:07:42"
        )
        let items = Self.build(snapshot: snap, defaultServerPort: 9848)

        guard case .header(let content) = items[0] else {
            Issue.record("status should live in custom header")
            return
        }
        #expect(content.endpoint == "100.64.0.1:9847")
        #expect(content.hasEndpoint)
        #expect(content.tone == .running)
        #expect(content.pid == 16027)
        #expect(content.uptime == "01:07:42")
    }

    @Test("paused snapshot reports that no endpoint is available")
    func pausedSnapshot() {
        let items = Self.build(snapshot: ServerStatusSnapshot(state: .paused))
        guard case .header(let content) = items[0] else {
            Issue.record("first item should be header")
            return
        }
        #expect(!content.hasEndpoint)
        #expect(content.endpoint == "Tailscale unavailable")
        #expect(content.tone == .paused)
    }

    @Test("Debug pairing is exposed only for an admitted pairable gateway")
    func debugObservation() {
        func debugActions(_ items: [MenuItemDescriptor]) -> [Bool] {
            items.compactMap { item in
                guard case .action(_, let enabled, let action) = item,
                      action == .showDebugPairingInfo else { return nil }
                return enabled
            }
        }

        #expect(debugActions(Self.build(snapshot: .checking, debugGateway: .unavailable)).isEmpty)
        #expect(debugActions(Self.build(
            snapshot: .checking,
            debugGateway: .admitted(isPairable: false)
        )) == [false])
        #expect(debugActions(Self.build(
            snapshot: .checking,
            debugGateway: .admitted(isPairable: true)
        )) == [true, false])
    }

    @Test("companion cannot mutate the production LaunchAgent")
    func companionDisablesProductionControls() {
        let items = Self.build(
            snapshot: ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847)),
            canManageLaunchAgent: false
        )
        let protectedActions: [MenuBarAction] = [.pauseServer, .restartServer, .uninstall]
        for item in items {
            guard case .action(_, let enabled, let action) = item,
                  protectedActions.contains(action) else { continue }
            #expect(!enabled)
        }
    }

    @Test("busy state disables the corresponding server control")
    func busyDisablesServerControls() {
        let items = Self.build(snapshot: ServerStatusSnapshot(state: .busy(.restarting)))
        let restart = items.compactMap { item -> Bool? in
            guard case .action(_, let enabled, let action) = item,
                  action == .restartServer else { return nil }
            return enabled
        }
        #expect(restart == [false])
    }

    @Test("Open Tron folder uses the configured tronHome path")
    func openFolderUsesPath() {
        let tronHome = URL(fileURLWithPath: "/tmp/custom-tron", isDirectory: true)
        let items = Self.build(snapshot: .checking, tronHome: tronHome)
        guard let openLink = items.first(where: { item in
            if case .openLink = item { return true }
            return false
        }), case .openLink(_, let url) = openLink else {
            Issue.record("expected an openLink for Open Tron folder")
            return
        }
        #expect(url == tronHome)
    }

    @Test("uptime formatter accepts bounded process elapsed-time formats")
    func uptimeFormatter() {
        #expect(MenuBarUptimeFormatter.parse("07:42") == 462)
        #expect(MenuBarUptimeFormatter.parse("01:07:42") == 4_062)
        #expect(MenuBarUptimeFormatter.parse("2-01:07:42") == 176_862)
        #expect(MenuBarUptimeFormatter.parse("1:bad") == nil)
        #expect(MenuBarUptimeFormatter.parse("1::02") == nil)
        #expect(MenuBarUptimeFormatter.display("07:42") == "00:07:42")
        #expect(MenuBarUptimeFormatter.display("2-01:07:42") == "2-01:07:42")
        #expect(MenuBarUptimeFormatter.display("unknown") == "unknown")
    }
}
