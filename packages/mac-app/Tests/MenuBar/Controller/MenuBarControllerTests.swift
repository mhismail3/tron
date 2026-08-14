import Foundation
import Testing
@testable import TronMac

@Suite("Menu bar controller")
@MainActor
struct MenuBarControllerTests {
    @Test("the controller presents the latest lifecycle snapshot")
    func appliesLatestSnapshot() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let dependencies = GatewayTestDependencies.make(root: root)
        let controller = MenuBarController(
            dependencies: dependencies,
            coordinator: GatewayLifecycleCoordinator(dependencies: dependencies)
        )
        let busy = GatewayStatusSnapshot(state: .busy(.restarting))
        let running = GatewayStatusSnapshot(
            state: .running(version: "1.2.3", port: 9848),
            tailscaleIP: "100.64.0.1"
        )

        controller.applySnapshot(busy)
        #expect(controller.snapshot == busy)
        controller.applySnapshot(running)
        #expect(controller.snapshot == running)
        controller.dispose()
    }
}
