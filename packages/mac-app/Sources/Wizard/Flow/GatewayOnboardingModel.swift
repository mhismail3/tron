import AppKit
import Foundation
import Observation

enum InstallOutcome: Equatable, Sendable {
    case ready
    case failed(GatewayLifecycleFailure)
}

enum PairingFailureReason: Equatable, Sendable {
    case noCode
    case gatewayUnreachable
    case localAuthenticationFailed
    case noTailscaleIP
    case qrGenerationFailed
}

/// Main-actor onboarding state machine. Views render state and emit intent;
/// this owner tracks every asynchronous probe and mutation.
@MainActor
@Observable
final class GatewayOnboardingModel {
    let dependencies: GatewayDependencies
    let coordinator: GatewayLifecycleCoordinator
    var step: WizardStep
    var tailscaleStatus: TailscaleStatus?
    var permissionStatuses: [Permission: PermissionStatus] = [:]
    var installStatus: GatewayInstallStatus = .none
    var installOutcome: InstallOutcome?
    var pairingPayload: PairingPayload?
    var pairingFailure: PairingFailureReason?
    var error: GatewayLifecycleFailure?
    var isMutating = false
    var isRefreshing = false

    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let completion: (@MainActor () async -> GatewayLifecycleFailure?)?

    init(
        dependencies: GatewayDependencies,
        coordinator: GatewayLifecycleCoordinator,
        initialStep: WizardStep = .welcome,
        initialError: GatewayLifecycleFailure? = nil,
        completion: (@MainActor () async -> GatewayLifecycleFailure?)? = nil
    ) {
        self.dependencies = dependencies
        self.coordinator = coordinator
        self.step = initialStep
        self.error = initialError
        self.completion = completion
    }

    deinit {
        probeTask?.cancel()
        operationTask?.cancel()
    }

    var canGoBack: Bool { step != .welcome && step != .done && !isMutating }
    var installIsReady: Bool { installOutcome == .ready }
    var permissionsAreReady: Bool {
        Permission.allCases.allSatisfy { permissionStatuses[$0] == .granted }
    }

    func resumeFromObservedState() {
        startProbe { [weak self] ticket in
            guard let self else { return }
            async let tailscale = dependencies.requirements.tailscaleStatus()
            async let permissions = dependencies.requirements.permissionStatuses()
            async let registration = dependencies.serviceManager.registrationStatus(
                configuration: dependencies.configuration
            )
            let observedTailscale = await tailscale
            let observedPermissions = await permissions
            let observedRegistration = await registration
            guard accept(ticket) else { return }

            tailscaleStatus = observedTailscale
            permissionStatuses = observedPermissions
            installStatus = Self.installStatus(observedRegistration)

            guard case .valid(let stored) = dependencies.stateStore.read(),
                  !stored.onboardingCompleted else { return }
            guard observedTailscale.isReady else {
                navigate(to: .tailscale)
                return
            }
            guard observedRegistration == .enabled else {
                navigate(to: .install)
                return
            }
            let health = await dependencies.healthChecker.check(
                bearerToken: dependencies.credentials.bearerToken()
            )
            guard accept(ticket) else { return }
            guard case .success = health else {
                navigate(to: .install)
                return
            }
            installOutcome = .ready
            navigate(to: permissionsAreReady ? .connectIPhone : .permissions)
        }
    }

    func advanceFromWelcome() { navigate(to: .tailscale) }

    func verifyTailscaleAndContinue() {
        startProbe { [weak self] ticket in
            guard let self else { return }
            let status = await dependencies.requirements.tailscaleStatus()
            guard accept(ticket) else { return }
            tailscaleStatus = status
            if status.isReady { navigate(to: .install) }
        }
    }

    func refreshPermissions() {
        startProbe { [weak self] ticket in
            guard let self else { return }
            let statuses = await dependencies.requirements.permissionStatuses()
            guard accept(ticket) else { return }
            permissionStatuses = statuses
        }
    }

    func install() {
        startMutation { [weak self] ticket in
            guard let self else { return }
            let result = await coordinator.perform(.install)
            guard accept(ticket) else { return }
            switch result {
            case .succeeded:
                installStatus = .registered(version: dependencies.currentVersion.canonicalVersion)
                installOutcome = .ready
                error = nil
            case .failed(let failure):
                installOutcome = .failed(failure)
                error = failure
                if failure == .approvalRequired { installStatus = .requiresApproval }
            case .busy:
                error = .serviceFailed
            case .needsOnboarding:
                error = .stateReadFailed
            }
        }
    }

    func continueAfterInstall() {
        guard installIsReady, !isMutating else { return }
        navigate(to: .permissions)
    }

    func restartAfterPermissions() {
        guard permissionsAreReady else { return }
        startMutation { [weak self] ticket in
            guard let self else { return }
            let result = await coordinator.perform(.restart)
            guard accept(ticket) else { return }
            switch result {
            case .succeeded:
                error = nil
                navigate(to: .connectIPhone)
            case .failed(let failure):
                error = failure
            case .busy:
                error = .serviceFailed
            case .needsOnboarding:
                error = .stateReadFailed
            }
        }
    }

    func refreshPairing(initialDelay: Bool = false) {
        startProbe { [weak self] ticket in
            guard let self else { return }
            pairingFailure = nil
            pairingPayload = nil
            if initialDelay {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
            guard accept(ticket) else { return }
            guard let token = dependencies.credentials.bearerToken(), !token.isEmpty else {
                pairingFailure = .localAuthenticationFailed
                return
            }
            guard case .success = await dependencies.healthChecker.check(bearerToken: token) else {
                guard accept(ticket) else { return }
                pairingFailure = .gatewayUnreachable
                return
            }
            guard accept(ticket) else { return }
            guard let code = dependencies.credentials.enrollmentCode() else {
                pairingFailure = .noCode
                return
            }
            guard case .signedIn(let host) = await dependencies.requirements.tailscaleStatus() else {
                guard accept(ticket) else { return }
                pairingFailure = .noTailscaleIP
                return
            }
            guard accept(ticket) else { return }
            pairingPayload = PairingPayload(
                host: host,
                port: dependencies.configuration.gatewayPort,
                code: code,
                label: LocalComputerName.current()
            )
        }
    }

    func continueAfterPairing() {
        guard pairingPayload != nil else { return }
        navigate(to: .done)
    }

    func completeOnboarding() {
        guard let completion else { return }
        startMutation { [weak self] ticket in
            guard let self else { return }
            let failure = await completion()
            guard accept(ticket) else { return }
            error = failure
        }
    }

    func goBack() {
        guard canGoBack,
              let index = WizardStep.allCases.firstIndex(of: step),
              index > 0 else { return }
        cancelProbe()
        navigate(to: WizardStep.allCases[index - 1])
    }

    func cancelAll() {
        generation += 1
        probeTask?.cancel()
        operationTask?.cancel()
        probeTask = nil
        operationTask = nil
        isRefreshing = false
        isMutating = false
    }

    private func startProbe(
        _ operation: @escaping @MainActor (Int) async -> Void
    ) {
        guard !isMutating else { return }
        cancelProbe()
        generation += 1
        let ticket = generation
        isRefreshing = true
        probeTask = Task { [weak self] in
            await operation(ticket)
            guard let self, accept(ticket) else { return }
            isRefreshing = false
            probeTask = nil
        }
    }

    private func startMutation(
        _ operation: @escaping @MainActor (Int) async -> Void
    ) {
        guard !isMutating else { return }
        cancelProbe()
        generation += 1
        let ticket = generation
        isMutating = true
        error = nil
        operationTask = Task { [weak self] in
            await operation(ticket)
            guard let self, accept(ticket) else { return }
            isMutating = false
            operationTask = nil
        }
    }

    private func cancelProbe() {
        generation += 1
        probeTask?.cancel()
        probeTask = nil
        isRefreshing = false
    }

    private func accept(_ ticket: Int) -> Bool {
        ticket == generation && !Task.isCancelled
    }

    private func navigate(to next: WizardStep) { step = next }

    private static func installStatus(
        _ status: GatewayServiceRegistrationStatus
    ) -> GatewayInstallStatus {
        switch status {
        case .enabled: .registered(version: nil)
        case .requiresApproval: .requiresApproval
        case .notRegistered: .none
        case .unavailable: .partial(reason: "Tron Gateway is unavailable")
        }
    }
}
