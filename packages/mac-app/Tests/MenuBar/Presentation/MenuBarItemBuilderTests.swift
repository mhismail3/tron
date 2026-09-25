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

    @Test("permission setup remains reachable after onboarding and while Gateway is busy")
    func permissionsRemainReachable() {
        for snapshot in [ServerStatusSnapshot.checking, .init(state: .busy(.restarting))] {
            let items = Self.build(snapshot: snapshot, canManageLaunchAgent: false)
            let permissionItems = items.compactMap { item -> Bool? in
                guard case .action(_, let enabled, .showPermissions) = item else { return nil }
                return enabled
            }
            #expect(permissionItems == [true])
        }
    }

    @Test("split update shows both identities and exposes one rerun action")
    func updateIncomplete() {
        let snapshot = ServerStatusSnapshot(state: .updateIncomplete(running: "abc123", selected: "release-7"))
        let items = Self.build(snapshot: snapshot)
        guard case .header(let header) = items[0] else {
            Issue.record("split update should be presented in the status header")
            return
        }
        #expect(header.status == "Update incomplete")
        #expect(snapshot.state.tooltip.contains("running abc123, selected release-7"))
        let actions = items.compactMap { item -> (String, MenuBarAction)? in
            guard case .action(let title, _, let action) = item else { return nil }
            return (title, action)
        }
        #expect(actions.filter { $0.1 == .updateGateway }.map(\.0) == ["Rerun Gateway Update"])
        #expect(actions.filter { $0.1 == .restartServer }.isEmpty)
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
