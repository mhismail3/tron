import Foundation

enum GatewayLifecycleCommand: Equatable, Sendable {
    case install
    case start
    case reconcileForLaunch
    case pause
    case resume
    case restart
    case completeOnboarding
    case uninstall(removeLocalAuthorization: Bool)
}

enum GatewayLifecycleFailure: Equatable, Sendable {
    case tailscaleUnavailable
    case approvalRequired
    case portInUse(Int)
    case invalidBundle
    case serviceRefused
    case serviceFailed
    case healthUnauthorized
    case healthUnavailable
    case stateReadFailed
    case stateWriteFailed
    case cleanupFailed([GatewayCleanupItem])
    case cancelled

    var userMessage: String {
        switch self {
        case .tailscaleUnavailable:
            "Connect Tailscale on this Mac, then try again."
        case .approvalRequired:
            "Approve Tron Gateway in System Settings > General > Login Items, then try again."
        case .portInUse(let port):
            "Another process is using port \(port). Stop it before starting Tron Gateway."
        case .invalidBundle:
            "The bundled Tron Gateway is invalid. Reinstall Tron."
        case .serviceRefused:
            "macOS refused the Tron Gateway operation. Check Login Items and try again."
        case .serviceFailed:
            "Tron Gateway did not reach the requested service state."
        case .healthUnauthorized:
            "Tron Gateway rejected local authorization. Restart it and try again."
        case .healthUnavailable:
            "Tron Gateway did not become reachable in time."
        case .stateReadFailed:
            "Tron's Mac setup record is invalid. Run setup again."
        case .stateWriteFailed:
            "Tron could not save Mac setup. Check disk permissions and try again."
        case .cleanupFailed:
            "Tron Gateway stopped, but some Mac setup files could not be removed. Try uninstall again."
        case .cancelled:
            "The operation was cancelled."
        }
    }
}

enum GatewayCleanupItem: String, Equatable, Sendable {
    case appState
    case localAuthorization
}

enum GatewayLifecycleResult: Equatable, Sendable {
    case succeeded(GatewayStatusSnapshot)
    case needsOnboarding
    case busy(GatewayLifecycleCommand)
    case failed(GatewayLifecycleFailure)
}

/// Sole owner of every mutating Gateway operation initiated by the Mac app.
///
/// Actor reentrancy is guarded by `activeOperation`: while an operation awaits
/// launchd, Tailscale, health, or disk, another mutation observes `.busy`
/// rather than interleaving with it. Every completion checks its operation ID
/// before publishing state.
actor GatewayLifecycleCoordinator {
    private struct ActiveOperation: Equatable {
        let id: UUID
        let command: GatewayLifecycleCommand
    }

    private struct PassiveRefresh {
        let id: UUID
        let task: Task<GatewayStatusSnapshot, Never>
    }

    private let dependencies: GatewayDependencies
    private var activeOperation: ActiveOperation?
    private var passiveRefresh: PassiveRefresh?
    private var latestSnapshot = GatewayStatusSnapshot.checking
    private var continuations: [UUID: AsyncStream<GatewayStatusSnapshot>.Continuation] = [:]

    init(dependencies: GatewayDependencies) {
        self.dependencies = dependencies
    }

    func snapshots() -> AsyncStream<GatewayStatusSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(latestSnapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func currentSnapshot() -> GatewayStatusSnapshot { latestSnapshot }

    func perform(_ command: GatewayLifecycleCommand) async -> GatewayLifecycleResult {
        if let activeOperation { return .busy(activeOperation.command) }
        passiveRefresh?.task.cancel()
        passiveRefresh = nil
        let operation = ActiveOperation(id: UUID(), command: command)
        activeOperation = operation
        publish(busySnapshot(for: command))
        defer {
            if activeOperation?.id == operation.id { activeOperation = nil }
        }

        do {
            try Task.checkCancellation()
            let result: GatewayLifecycleResult
            switch command {
            case .install:
                result = await prepareGateway(operation: operation, completingOnboarding: false, forceRestart: false)
            case .start:
                result = await prepareGateway(
                    operation: operation,
                    completingOnboarding: onboardingIsComplete,
                    forceRestart: false
                )
            case .reconcileForLaunch:
                result = await reconcile(operation: operation)
            case .pause:
                result = await pause(operation: operation)
            case .resume:
                result = await prepareGateway(operation: operation, completingOnboarding: true, forceRestart: false)
            case .restart:
                result = await restart(operation: operation)
            case .completeOnboarding:
                result = await completeOnboarding(operation: operation)
            case .uninstall(let removeLocalAuthorization):
                result = await uninstall(
                    operation: operation,
                    removeLocalAuthorization: removeLocalAuthorization
                )
            }
            guard activeOperation?.id == operation.id else { return .failed(.cancelled) }
            if case .succeeded(let snapshot) = result { publish(snapshot) }
            if case .failed = result { publish(await statusSnapshot()) }
            return result
        } catch is CancellationError {
            guard activeOperation?.id == operation.id else { return .failed(.cancelled) }
            publish(await statusSnapshot())
            return .failed(.cancelled)
        } catch {
            publish(await statusSnapshot())
            return .failed(.serviceFailed)
        }
    }

    func refreshStatus() async -> GatewayStatusSnapshot {
        if activeOperation != nil { return latestSnapshot }
        if let passiveRefresh { return await passiveRefresh.task.value }

        let id = UUID()
        let task = Task { await self.statusSnapshot() }
        passiveRefresh = PassiveRefresh(id: id, task: task)
        let snapshot = await task.value
        guard passiveRefresh?.id == id else { return latestSnapshot }
        passiveRefresh = nil
        guard activeOperation == nil else { return latestSnapshot }
        publish(snapshot)
        return snapshot
    }

    private func reconcile(operation: ActiveOperation) async -> GatewayLifecycleResult {
        switch dependencies.stateStore.read() {
        case .missing:
            publish(await statusSnapshot())
            return .needsOnboarding
        case .corrupt:
            publish(await statusSnapshot())
            return .failed(.stateReadFailed)
        case .valid(let state):
            guard state.onboardingCompleted else {
                publish(await statusSnapshot())
                return .needsOnboarding
            }
            let forceRestart = state.preparedVersion != dependencies.currentVersion
            return await prepareGateway(
                operation: operation,
                completingOnboarding: true,
                forceRestart: forceRestart
            )
        }
    }

    private func prepareGateway(
        operation: ActiveOperation,
        completingOnboarding: Bool,
        forceRestart: Bool
    ) async -> GatewayLifecycleResult {
        guard case .signedIn = await dependencies.requirements.tailscaleStatus() else {
            return .failed(.tailscaleUnavailable)
        }
        guard isCurrent(operation) else { return .failed(.cancelled) }

        let registration = await dependencies.serviceManager.register(
            configuration: dependencies.configuration
        )
        if let failure = failure(for: registration) { return .failed(failure) }
        guard isCurrent(operation) else { return .failed(.cancelled) }

        var health = await dependencies.healthChecker.check(
            bearerToken: dependencies.credentials.bearerToken()
        )
        if forceRestart || !health.isHealthy {
            let restart = await dependencies.serviceManager.restart(
                configuration: dependencies.configuration
            )
            if let failure = failure(for: restart) { return .failed(failure) }
            health = await waitForHealthy(operation: operation)
        }
        guard isCurrent(operation) else { return .failed(.cancelled) }
        guard case .success = health else { return .failed(healthFailure(health)) }

        do {
            try dependencies.stateStore.write(GatewayAppState(
                onboardingCompleted: completingOnboarding,
                preparedVersion: dependencies.currentVersion
            ))
        } catch {
            return .failed(.stateWriteFailed)
        }
        return .succeeded(await statusSnapshot())
    }

    private func completeOnboarding(operation: ActiveOperation) async -> GatewayLifecycleResult {
        let health = await dependencies.healthChecker.check(
            bearerToken: dependencies.credentials.bearerToken()
        )
        guard case .success = health else { return .failed(healthFailure(health)) }
        guard isCurrent(operation) else { return .failed(.cancelled) }
        do {
            try dependencies.stateStore.write(GatewayAppState(
                onboardingCompleted: true,
                preparedVersion: dependencies.currentVersion
            ))
        } catch {
            return .failed(.stateWriteFailed)
        }
        return .succeeded(await statusSnapshot())
    }

    private func pause(operation: ActiveOperation) async -> GatewayLifecycleResult {
        let outcome = await dependencies.serviceManager.unregister(
            configuration: dependencies.configuration
        )
        guard isCurrent(operation) else { return .failed(.cancelled) }
        if let failure = failure(for: outcome) { return .failed(failure) }
        return .succeeded(await statusSnapshot())
    }

    private func restart(operation: ActiveOperation) async -> GatewayLifecycleResult {
        let outcome = await dependencies.serviceManager.restart(
            configuration: dependencies.configuration
        )
        guard isCurrent(operation) else { return .failed(.cancelled) }
        if let failure = failure(for: outcome) { return .failed(failure) }
        let health = await waitForHealthy(operation: operation)
        guard case .success = health else { return .failed(healthFailure(health)) }
        return .succeeded(await statusSnapshot())
    }

    private func uninstall(
        operation: ActiveOperation,
        removeLocalAuthorization: Bool
    ) async -> GatewayLifecycleResult {
        let outcome = await dependencies.serviceManager.unregister(
            configuration: dependencies.configuration
        )
        guard isCurrent(operation) else { return .failed(.cancelled) }
        if let failure = failure(for: outcome) { return .failed(failure) }

        let registration = await dependencies.serviceManager.registrationStatus(
            configuration: dependencies.configuration
        )
        let loaded = await dependencies.serviceManager.isLoaded(
            configuration: dependencies.configuration
        )
        guard (registration == .notRegistered || registration == .unavailable), !loaded else {
            return .failed(.serviceFailed)
        }

        var cleanupFailures: [GatewayCleanupItem] = []
        do {
            try dependencies.stateStore.remove()
        } catch {
            cleanupFailures.append(.appState)
        }
        if removeLocalAuthorization,
           FileManager.default.fileExists(atPath: dependencies.configuration.bearerTokenPath.path) {
            do {
                try FileManager.default.removeItem(at: dependencies.configuration.bearerTokenPath)
            } catch {
                cleanupFailures.append(.localAuthorization)
            }
        }
        if !cleanupFailures.isEmpty { return .failed(.cleanupFailed(cleanupFailures)) }
        return .succeeded(await statusSnapshot())
    }

    private func waitForHealthy(operation: ActiveOperation) async -> GatewayHealthResult {
        var last: GatewayHealthResult = .unreachable
        for attempt in 0..<dependencies.healthPolicy.attempts {
            guard isCurrent(operation), !Task.isCancelled else { return .unreachable }
            last = await dependencies.healthChecker.check(
                bearerToken: dependencies.credentials.bearerToken()
            )
            if last.isHealthy || last == .unauthorized { return last }
            if attempt + 1 < dependencies.healthPolicy.attempts {
                do {
                    try await Task.sleep(nanoseconds: dependencies.healthPolicy.delayNanoseconds)
                } catch {
                    return .unreachable
                }
            }
        }
        return last
    }

    private func statusSnapshot() async -> GatewayStatusSnapshot {
        let token = dependencies.credentials.bearerToken()
        let health = await dependencies.healthChecker.check(bearerToken: token)
        switch health {
        case .success(let info):
            let runtime = await dependencies.serviceManager.runtimeInfo(
                configuration: dependencies.configuration
            )
            let tailscale = await dependencies.requirements.tailscaleStatus()
            return GatewayStatusSnapshot(
                state: .running(version: info.version, port: dependencies.configuration.gatewayPort),
                tailscaleIP: tailscale.displayIP,
                processID: runtime?.pid,
                uptime: runtime?.uptime
            )
        case .unauthorized:
            return GatewayStatusSnapshot(state: .unauthorized)
        case .unreachable, .timeout, .malformedResponse:
            let loaded = await dependencies.serviceManager.isLoaded(
                configuration: dependencies.configuration
            )
            return GatewayStatusSnapshot(
                state: loaded ? .failed(reason: health.statusReason) : .paused
            )
        }
    }

    private func failure(for outcome: GatewayServiceOutcome) -> GatewayLifecycleFailure? {
        switch outcome {
        case .registered, .alreadyRegistered, .unregistered:
            nil
        case .requiresApproval:
            .approvalRequired
        case .portInUse(let port):
            .portInUse(port)
        case .invalidBundle:
            .invalidBundle
        case .refused:
            .serviceRefused
        case .failed:
            .serviceFailed
        }
    }

    private func healthFailure(_ health: GatewayHealthResult) -> GatewayLifecycleFailure {
        health == .unauthorized ? .healthUnauthorized : .healthUnavailable
    }

    private func busySnapshot(for command: GatewayLifecycleCommand) -> GatewayStatusSnapshot {
        let action: GatewayBusyAction = switch command {
        case .install, .start, .reconcileForLaunch, .completeOnboarding: .starting
        case .pause: .pausing
        case .resume: .resuming
        case .restart: .restarting
        case .uninstall: .uninstalling
        }
        return GatewayStatusSnapshot(
            state: .busy(action),
            tailscaleIP: latestSnapshot.tailscaleIP,
            processID: latestSnapshot.processID,
            uptime: latestSnapshot.uptime
        )
    }

    private func isCurrent(_ operation: ActiveOperation) -> Bool {
        activeOperation?.id == operation.id && !Task.isCancelled
    }

    private var onboardingIsComplete: Bool {
        guard case .valid(let state) = dependencies.stateStore.read() else { return false }
        return state.onboardingCompleted
    }

    private func publish(_ snapshot: GatewayStatusSnapshot) {
        latestSnapshot = snapshot
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

private extension GatewayHealthResult {
    var isHealthy: Bool {
        if case .success = self { return true }
        return false
    }

    var statusReason: String {
        switch self {
        case .success: "healthy"
        case .unauthorized: "unauthorized"
        case .unreachable: "unreachable"
        case .timeout: "timeout"
        case .malformedResponse: "invalid response"
        }
    }
}
