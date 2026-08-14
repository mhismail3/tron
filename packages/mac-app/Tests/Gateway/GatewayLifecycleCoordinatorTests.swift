import Foundation
import Testing
@testable import TronMac

@Suite("Gateway lifecycle coordinator")
struct GatewayLifecycleCoordinatorTests {
    @Test("install registers, verifies health, and writes incomplete onboarding state")
    func installWritesPreparedState() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let service = MockGatewayServiceManager()
        let health = MockGatewayHealthChecker([.unreachable, .success(GatewayHealthInfo(version: "1.2.3"))])
        let state = MockGatewayStateStore()
        let dependencies = GatewayTestDependencies.make(root: root, service: service, health: health, state: state)
        let coordinator = GatewayLifecycleCoordinator(dependencies: dependencies)

        let result = await coordinator.perform(.install)

        guard case .succeeded = result else {
            Issue.record("Expected successful install, got \(result)")
            return
        }
        #expect(service.calls == [.register, .restart, .runtime])
        #expect(state.writes == [GatewayAppState(
            onboardingCompleted: false,
            preparedVersion: GatewayTestDependencies.version
        )])
    }

    @Test("a concurrent mutation is rejected as busy")
    func rejectsConcurrentMutation() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let service = MockGatewayServiceManager()
        service.operationDelayNanoseconds = 200_000_000
        let dependencies = GatewayTestDependencies.make(root: root, service: service)
        let coordinator = GatewayLifecycleCoordinator(dependencies: dependencies)

        let first = Task { await coordinator.perform(.install) }
        try await Task.sleep(for: .milliseconds(30))
        let duplicate = await coordinator.perform(.restart)

        #expect(duplicate == .busy(.install))
        _ = await first.value
    }

    @Test("cancelled work cannot write a stale completion")
    func cancellationRejectsStaleCompletion() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let health = MockGatewayHealthChecker([.success(GatewayHealthInfo(version: "1.2.3"))])
        health.delayNanoseconds = 300_000_000
        let state = MockGatewayStateStore()
        let dependencies = GatewayTestDependencies.make(root: root, health: health, state: state)
        let coordinator = GatewayLifecycleCoordinator(dependencies: dependencies)

        let task = Task { await coordinator.perform(.install) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let result = await task.value

        #expect(result == .failed(.cancelled))
        #expect(state.writes.isEmpty)
    }

    @Test("update reconciliation restarts before recording the new app version")
    func updateReconciliation() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let oldVersion = GatewayAppVersion(canonicalVersion: "1.2.2", buildNumber: "122")
        let state = MockGatewayStateStore(.valid(GatewayAppState(
            onboardingCompleted: true,
            preparedVersion: oldVersion
        )))
        let service = MockGatewayServiceManager()
        service.status = .enabled
        let dependencies = GatewayTestDependencies.make(root: root, service: service, state: state)
        let coordinator = GatewayLifecycleCoordinator(dependencies: dependencies)

        guard case .succeeded = await coordinator.perform(.reconcileForLaunch) else {
            Issue.record("Expected successful update reconciliation")
            return
        }

        #expect(service.calls.contains(.restart))
        #expect(state.writes.last?.preparedVersion == GatewayTestDependencies.version)
        #expect(state.writes.last?.onboardingCompleted == true)
    }

    @Test("corrupt state visibly requires repair")
    func corruptStateFails() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let dependencies = GatewayTestDependencies.make(
            root: root,
            state: MockGatewayStateStore(.corrupt)
        )
        let coordinator = GatewayLifecycleCoordinator(dependencies: dependencies)

        #expect(await coordinator.perform(.reconcileForLaunch) == .failed(.stateReadFailed))
    }

    @Test(arguments: [
        (GatewayServiceOutcome.requiresApproval, GatewayLifecycleFailure.approvalRequired),
        (GatewayServiceOutcome.portInUse(9848), GatewayLifecycleFailure.portInUse(9848)),
        (GatewayServiceOutcome.invalidBundle, GatewayLifecycleFailure.invalidBundle),
        (GatewayServiceOutcome.refused, GatewayLifecycleFailure.serviceRefused),
        (GatewayServiceOutcome.failed, GatewayLifecycleFailure.serviceFailed),
    ])
    func registrationFailuresAreTyped(
        outcome: GatewayServiceOutcome,
        expected: GatewayLifecycleFailure
    ) async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let service = MockGatewayServiceManager()
        service.registerOutcome = outcome
        let coordinator = GatewayLifecycleCoordinator(
            dependencies: GatewayTestDependencies.make(root: root, service: service)
        )

        #expect(await coordinator.perform(.install) == .failed(expected))
    }

    @Test("unauthorized health is not treated as availability failure")
    func unauthorizedHealthIsTyped() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let coordinator = GatewayLifecycleCoordinator(
            dependencies: GatewayTestDependencies.make(
                root: root,
                health: MockGatewayHealthChecker([.unauthorized])
            )
        )

        #expect(await coordinator.perform(.install) == .failed(.healthUnauthorized))
    }

    @Test("onboarding completion preserves the authenticated health failure category")
    func onboardingCompletionPreservesHealthFailure() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let state = MockGatewayStateStore()
        let coordinator = GatewayLifecycleCoordinator(
            dependencies: GatewayTestDependencies.make(
                root: root,
                health: MockGatewayHealthChecker([.unauthorized]),
                state: state
            )
        )

        #expect(await coordinator.perform(.completeOnboarding) == .failed(.healthUnauthorized))
        #expect(state.writes.isEmpty)
    }

    @Test("uninstall is idempotent and preserves durable Gateway data")
    func uninstallPreservesDurableData() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let service = MockGatewayServiceManager()
        service.status = .notRegistered
        let state = MockGatewayStateStore(.valid(GatewayAppState(
            onboardingCompleted: true,
            preparedVersion: GatewayTestDependencies.version
        )))
        let dependencies = GatewayTestDependencies.make(root: root, service: service, state: state)
        try FileManager.default.createDirectory(
            at: dependencies.configuration.gatewayDirectory,
            withIntermediateDirectories: true
        )
        let enrollment = dependencies.configuration.enrollmentCodePath
        try Data("durable".utf8).write(to: enrollment)
        let coordinator = GatewayLifecycleCoordinator(dependencies: dependencies)

        guard case .succeeded = await coordinator.perform(.uninstall(removeLocalAuthorization: false)) else {
            Issue.record("Expected idempotent uninstall")
            return
        }

        #expect(state.removeCount == 1)
        #expect(FileManager.default.fileExists(atPath: enrollment.path))
        #expect(service.calls == [.unregister, .status, .loaded, .runtime])
    }

    @Test("partial cleanup failures remain recoverable")
    func cleanupFailureIsReported() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let state = MockGatewayStateStore()
        state.failRemovals = true
        let coordinator = GatewayLifecycleCoordinator(
            dependencies: GatewayTestDependencies.make(root: root, state: state)
        )

        #expect(
            await coordinator.perform(.uninstall(removeLocalAuthorization: false))
                == .failed(.cleanupFailed([.appState]))
        )
    }

    @Test("concurrent passive refreshes share one health probe")
    func coalescesPassiveRefreshes() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let health = MockGatewayHealthChecker()
        health.delayNanoseconds = 150_000_000
        let coordinator = GatewayLifecycleCoordinator(
            dependencies: GatewayTestDependencies.make(root: root, health: health)
        )

        async let first = coordinator.refreshStatus()
        async let second = coordinator.refreshStatus()
        _ = await (first, second)

        #expect(health.callCount == 1)
    }
}
