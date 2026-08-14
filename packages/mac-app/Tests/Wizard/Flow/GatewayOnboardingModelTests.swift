import Foundation
import Testing
@testable import TronMac

@Suite("Gateway onboarding model")
@MainActor
struct GatewayOnboardingModelTests {
    @Test("fresh onboarding starts at welcome without persisted transient state")
    func freshState() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let dependencies = GatewayTestDependencies.make(root: root)
        let model = GatewayOnboardingModel(
            dependencies: dependencies,
            coordinator: GatewayLifecycleCoordinator(dependencies: dependencies)
        )

        #expect(model.step == .welcome)
        #expect(model.pairingPayload == nil)
        #expect(model.installOutcome == nil)
        #expect(!model.isMutating)
        #expect(!model.isRefreshing)
    }

    @Test("observed truth resumes at the earliest incomplete step")
    func interruptedRecovery() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let state = MockGatewayStateStore(.valid(GatewayAppState(
            onboardingCompleted: false,
            preparedVersion: GatewayTestDependencies.version
        )))
        let service = MockGatewayServiceManager()
        service.status = .enabled
        let requirements = MockGatewayRequirements(
            permissions: [.fullDiskAccess: .denied]
        )
        let dependencies = GatewayTestDependencies.make(
            root: root,
            service: service,
            state: state,
            requirements: requirements
        )
        let model = GatewayOnboardingModel(
            dependencies: dependencies,
            coordinator: GatewayLifecycleCoordinator(dependencies: dependencies)
        )

        model.resumeFromObservedState()
        try await waitUntil { model.step == .permissions && !model.isRefreshing }

        #expect(model.installOutcome == .ready)
        #expect(model.permissionStatuses[.fullDiskAccess] == .denied)
    }

    @Test("unavailable Tailscale is the earliest visible repair step")
    func tailscaleRepairStep() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let state = MockGatewayStateStore(.valid(GatewayAppState(
            onboardingCompleted: false,
            preparedVersion: GatewayTestDependencies.version
        )))
        let requirements = MockGatewayRequirements(tailscale: .installedNotSignedIn)
        let dependencies = GatewayTestDependencies.make(
            root: root,
            state: state,
            requirements: requirements
        )
        let model = GatewayOnboardingModel(
            dependencies: dependencies,
            coordinator: GatewayLifecycleCoordinator(dependencies: dependencies)
        )

        model.resumeFromObservedState()
        try await waitUntil { model.step == .tailscale && !model.isRefreshing }
        #expect(model.tailscaleStatus == .installedNotSignedIn)
    }

    @Test("a stale Tailscale probe cannot overwrite backward navigation")
    func staleProbeCannotAdvance() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let requirements = MockGatewayRequirements()
        requirements.delayNanoseconds = 150_000_000
        let dependencies = GatewayTestDependencies.make(root: root, requirements: requirements)
        let model = GatewayOnboardingModel(
            dependencies: dependencies,
            coordinator: GatewayLifecycleCoordinator(dependencies: dependencies),
            initialStep: .tailscale
        )

        model.verifyTailscaleAndContinue()
        model.goBack()
        try await Task.sleep(for: .milliseconds(250))

        #expect(model.step == .welcome)
    }

    @Test("repeated install clicks start one mutation and disable Back")
    func repeatedInstallClicks() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let service = MockGatewayServiceManager()
        service.operationDelayNanoseconds = 150_000_000
        let dependencies = GatewayTestDependencies.make(root: root, service: service)
        let model = GatewayOnboardingModel(
            dependencies: dependencies,
            coordinator: GatewayLifecycleCoordinator(dependencies: dependencies),
            initialStep: .install
        )

        model.install()
        model.install()
        #expect(model.isMutating)
        #expect(!model.canGoBack)
        try await waitUntil { !model.isMutating }

        #expect(service.calls.filter { $0 == .register }.count == 1)
        #expect(model.installOutcome == .ready)
    }

    @Test("starting a mutation cancels probes and blocks new probes")
    func mutationOwnsAsyncWork() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let service = MockGatewayServiceManager()
        service.operationDelayNanoseconds = 150_000_000
        let requirements = MockGatewayRequirements()
        requirements.delayNanoseconds = 150_000_000
        let dependencies = GatewayTestDependencies.make(
            root: root,
            service: service,
            requirements: requirements
        )
        let model = GatewayOnboardingModel(
            dependencies: dependencies,
            coordinator: GatewayLifecycleCoordinator(dependencies: dependencies),
            initialStep: .install
        )

        model.refreshPermissions()
        #expect(model.isRefreshing)
        model.install()
        #expect(!model.isRefreshing)
        #expect(model.isMutating)
        model.refreshPermissions()
        #expect(!model.isRefreshing)

        try await waitUntil { !model.isMutating }
        #expect(model.installOutcome == .ready)
    }

    @Test("permission restart failure blocks the connection step")
    func permissionRestartFailure() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let service = MockGatewayServiceManager()
        service.restartOutcome = .failed
        let dependencies = GatewayTestDependencies.make(root: root, service: service)
        let model = GatewayOnboardingModel(
            dependencies: dependencies,
            coordinator: GatewayLifecycleCoordinator(dependencies: dependencies),
            initialStep: .permissions
        )
        model.permissionStatuses = [.fullDiskAccess: .granted]

        model.restartAfterPermissions()
        try await waitUntil { !model.isMutating }

        #expect(model.step == .permissions)
        #expect(model.error == .serviceFailed)
    }

    @Test("missing pairing data remains retryable and ephemeral")
    func pairingStateIsEphemeral() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let dependencies = GatewayTestDependencies.make(
            root: root,
            credentials: MockGatewayCredentials(token: "token", code: nil)
        )
        let coordinator = GatewayLifecycleCoordinator(dependencies: dependencies)
        let model = GatewayOnboardingModel(
            dependencies: dependencies,
            coordinator: coordinator,
            initialStep: .connectIPhone
        )

        model.refreshPairing()
        try await waitUntil { !model.isRefreshing }
        #expect(model.pairingFailure == .noCode)
        #expect(model.pairingPayload == nil)

        let reopened = GatewayOnboardingModel(
            dependencies: dependencies,
            coordinator: coordinator,
            initialStep: .connectIPhone
        )
        #expect(reopened.pairingFailure == nil)
        #expect(reopened.pairingPayload == nil)
    }

    @Test("completion reports the coordinator failure category")
    func completionFailure() async throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let dependencies = GatewayTestDependencies.make(root: root)
        let model = GatewayOnboardingModel(
            dependencies: dependencies,
            coordinator: GatewayLifecycleCoordinator(dependencies: dependencies),
            initialStep: .done,
            completion: { .stateWriteFailed }
        )

        model.completeOnboarding()
        try await waitUntil { !model.isMutating }
        #expect(model.error == .stateWriteFailed)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for onboarding state")
    }
}
