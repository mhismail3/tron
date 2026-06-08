import Foundation
import Testing
@testable import TronMac

@Suite("MenuBarController")
@MainActor
struct MenuBarControllerTests {
    @Test("passive poll refreshes do not overwrite in-flight busy status")
    func passivePollDoesNotOverwriteBusyStatus() {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let controller = MenuBarController(setup: MenuBarItemBuilderTests.makeSetup(in: tmp))

        controller.applySnapshot(ServerStatusSnapshot(state: .busy(.restarting)))
        controller.applyPolledSnapshot(ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847)))

        #expect(controller.snapshot.state == .busy(.restarting))

        controller.applySnapshot(ServerStatusSnapshot(state: .running(version: "0.5.0", port: 9847)))
        #expect(controller.snapshot.state == .running(version: "0.5.0", port: 9847))
    }
}
