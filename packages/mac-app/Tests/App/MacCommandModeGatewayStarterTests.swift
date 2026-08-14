import Foundation
import Testing
@testable import TronMac

@Suite("Mac command-mode Gateway starter")
struct MacCommandModeGatewayStarterTests {
    @Test("successful command start uses the lifecycle coordinator")
    func successfulStart() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let state = MockGatewayStateStore(.valid(GatewayAppState(
            onboardingCompleted: true,
            preparedVersion: GatewayTestDependencies.version
        )))
        let coordinator = GatewayLifecycleCoordinator(
            dependencies: GatewayTestDependencies.make(root: root, state: state)
        )

        #expect(await MacCommandModeGatewayStarter.start(coordinator: coordinator) == .ok)
        #expect(state.writes.last?.onboardingCompleted == true)
    }

    @Test("unhealthy command start returns a typed failure without writing state")
    func unhealthyStart() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let state = MockGatewayStateStore()
        let coordinator = GatewayLifecycleCoordinator(
            dependencies: GatewayTestDependencies.make(
                root: root,
                health: MockGatewayHealthChecker([.unreachable]),
                state: state
            )
        )

        #expect(
            await MacCommandModeGatewayStarter.start(coordinator: coordinator)
                == .failed(.healthUnavailable)
        )
        #expect(state.writes.isEmpty)
    }
}
