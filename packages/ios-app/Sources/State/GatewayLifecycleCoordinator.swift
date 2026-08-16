import Foundation
import Observation
import UIKit

enum GatewayConnectionState: Equatable {
    case unpaired, connecting, connected, reconnecting, unauthorized, offline(String)
}

typealias GatewayPairingCommit = @MainActor @Sendable (GatewayProfile, String) throws -> Void
typealias GatewayProfileTokenLookup = @MainActor @Sendable (GatewayProfile) -> String?

@MainActor
protocol GatewayLifecycleProjectionDelegate: AnyObject, Sendable {
    func lifecycleLoadCache(
        profileID: String,
        admission: GatewayLifecycleCoordinator.Admission
    ) async
    func lifecycleInvalidateSessionConnectionOwnership()
    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async
    func lifecycleRestoreMountedPresentation(admission: GatewayLifecycleCoordinator.Admission) async
    func lifecycleReattachTerminals(admission: GatewayLifecycleCoordinator.Admission) async
    func lifecycleReconcileForeground(admission: GatewayLifecycleCoordinator.Admission) async throws
    func lifecycleRetireProjection(final: Bool) async
    func lifecycleSurface(_ error: Error)
}

@MainActor
@Observable
final class GatewayLifecycleCoordinator {
    struct Admission: Equatable, Sendable {
        let generation: Int
        let connectionID: Int?
    }

    private struct PairingAttempt {
        let id: UUID
        let task: Task<Void, Error>
        let previousConnectionState: GatewayConnectionState
    }

    private enum Phase {
        case active(Int)
        case transitioning(Int)
        case tornDown(Int)

        var generation: Int {
            switch self {
            case .active(let generation), .transitioning(let generation), .tornDown(let generation):
                generation
            }
        }

        var admitsWork: Bool {
            if case .active = self { return true }
            return false
        }
    }

    let client: GatewayClient
    let profiles: GatewayProfileStore

    private let clock: MonotonicClock
    private let reconnectDelayPolicy: ReconnectDelayPolicy
    private let uuidSource: UUIDSource
    private let pairer: GatewayPairer
    private let pairingCommit: GatewayPairingCommit
    private let profileTokenLookup: GatewayProfileTokenLookup

    weak var delegate: (any GatewayLifecycleProjectionDelegate)?

    private(set) var connectionState: GatewayConnectionState = .unpaired
    private(set) var hasResolvedLaunchState = false
    private(set) var gatewayInfo: GatewayInfo?
    private(set) var connectionID: Int?

    private var phase: Phase = .active(0)
    private var completedTransitionGeneration = 0
    private var transitionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var transitionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var committedConnectionTask: Task<Void, Never>?
    private var reconnectAttemptGeneration = 0
    private var reconnectCanBeAccelerated = false
    private var pairingAttempt: PairingAttempt?
    private var foregroundReconciliationTask: Task<Void, Never>?
    private var foregroundReconciliationGeneration = 0

    init(
        client: GatewayClient,
        profiles: GatewayProfileStore,
        clock: MonotonicClock,
        reconnectDelayPolicy: ReconnectDelayPolicy,
        uuidSource: UUIDSource,
        pairer: GatewayPairer,
        pairingCommit: @escaping GatewayPairingCommit,
        profileTokenLookup: @escaping GatewayProfileTokenLookup
    ) {
        self.client = client
        self.profiles = profiles
        self.clock = clock
        self.reconnectDelayPolicy = reconnectDelayPolicy
        self.uuidSource = uuidSource
        self.pairer = pairer
        self.pairingCommit = pairingCommit
        self.profileTokenLookup = profileTokenLookup
    }

    var admission: Admission? {
        guard phase.admitsWork else { return nil }
        return Admission(generation: phase.generation, connectionID: connectionID)
    }

    var generationAdmission: Admission? {
        guard phase.admitsWork else { return nil }
        return Admission(generation: phase.generation, connectionID: nil)
    }

    var selectedProfileID: String? {
        if let selected = profiles.selected?.id { return selected }
        #if HOSTED_TEST
        return hostedProfileID
        #else
        return nil
        #endif
    }

    var admitsWork: Bool { phase.admitsWork }

    func admits(_ admission: Admission) -> Bool {
        guard phase.admitsWork, phase.generation == admission.generation else { return false }
        guard let expectedConnectionID = admission.connectionID else { return true }
        return connectionID == expectedConnectionID
    }

    func admitsEvent(connectionID deliveredConnectionID: Int?) -> Bool {
        guard phase.admitsWork else { return false }
        guard let deliveredConnectionID else { return true }
        return connectionID == deliveredConnectionID
    }

    func require(_ admission: Admission) throws {
        try Task.checkCancellation()
        guard admits(admission) else { throw CancellationError() }
    }

    func requireConnection(_ admission: Admission) throws {
        try require(admission)
        guard let expectedConnectionID = admission.connectionID,
              connectionID == expectedConnectionID else { throw CancellationError() }
    }

    func start() async {
        guard phase.admitsWork,
              connectionState != .connecting,
              connectionState != .connected,
              connectionState != .reconnecting else { return }
        guard let profile = profiles.selected, let token = profileTokenLookup(profile) else {
            connectionState = .unpaired
            hasResolvedLaunchState = true
            return
        }
        let admission = Admission(generation: phase.generation, connectionID: nil)
        await delegate?.lifecycleLoadCache(profileID: profile.id, admission: admission)
        guard admits(admission) else { return }
        await connect(profile: profile, token: token, admission: admission)
        guard admitsGeneration(admission.generation) else { return }
        hasResolvedLaunchState = true
    }

    @discardableResult
    func becameActive() -> Task<Void, Never>? {
        guard phase.admitsWork else { return nil }
        guard connectionState == .connected else {
            switch connectionState {
            case .offline, .reconnecting:
                requestReconnect(immediate: true, replaceExisting: true)
                return reconnectTask
            case .unpaired, .unauthorized, .connecting, .connected:
                return nil
            }
        }
        if let foregroundReconciliationTask { return foregroundReconciliationTask }
        guard let admission else { return nil }
        foregroundReconciliationGeneration &+= 1
        let reconciliationGeneration = foregroundReconciliationGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.foregroundReconciliationGeneration == reconciliationGeneration {
                    self.foregroundReconciliationTask = nil
                }
            }
            do {
                try await self.delegate?.lifecycleReconcileForeground(admission: admission)
                try self.require(admission)
            } catch is CancellationError {
                return
            } catch {
                guard self.admits(admission) else { return }
                self.delegate?.lifecycleInvalidateSessionConnectionOwnership()
                self.requestReconnect(immediate: true, replaceExisting: true)
            }
        }
        foregroundReconciliationTask = task
        return task
    }

    /// Backgrounding suspends disposable reconciliation work without retiring
    /// the selected route or responsive socket. The next active scene owns a
    /// fresh convergence pass.
    func enteredBackground() {
        foregroundReconciliationGeneration &+= 1
        let task = foregroundReconciliationTask
        foregroundReconciliationTask = nil
        task?.cancel()
    }

    func pair(_ invitation: PairingInvitation) async throws {
        guard phase.admitsWork else { throw CancellationError() }
        let previousConnectionState = pairingAttempt?.previousConnectionState ?? connectionState
        invalidatePairingAttempt()
        let lifecycleGeneration = phase.generation
        let attemptID = uuidSource.next()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performPair(invitation, attemptID: attemptID)
        }
        pairingAttempt = PairingAttempt(
            id: attemptID,
            task: task,
            previousConnectionState: previousConnectionState
        )
        defer {
            if pairingAttempt?.id == attemptID { pairingAttempt = nil }
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if pairingAttempt?.id == attemptID, admitsGeneration(lifecycleGeneration) {
                connectionState = previousConnectionState
            }
            throw error
        }
    }

    func switchGateway(_ profile: GatewayProfile) async {
        if case .tornDown = phase { return }
        let generation = await beginTransition()
        guard phase.generation == generation else { return }
        guard let token = profileTokenLookup(profile) else {
            finishTransition(generation)
            connectionState = .unpaired
            hasResolvedLaunchState = true
            delegate?.lifecycleSurface(GatewayFailure(
                code: "missing_token",
                message: "This gateway no longer has a Keychain token. Pair it again.",
                retryable: false,
                details: nil
            ))
            return
        }
        profiles.select(profile)
        finishTransition(generation)
        let admission = Admission(generation: generation, connectionID: nil)
        await delegate?.lifecycleLoadCache(profileID: profile.id, admission: admission)
        guard admits(admission) else { return }
        await connect(profile: profile, token: token, admission: admission)
    }

    @discardableResult
    func forgetCurrentGateway() async -> Bool {
        guard !isTornDown else { return false }
        let generation = await beginTransition()
        guard phase.generation == generation else { return false }
        if let profile = profiles.selected { profiles.remove(profile) }
        finishTransition(generation)
        connectionState = .unpaired
        hasResolvedLaunchState = true
        return true
    }

    @discardableResult
    func forget(profile: GatewayProfile) async -> Bool {
        guard !isTornDown else { return false }
        let generation = await beginTransition()
        guard phase.generation == generation else { return false }
        profiles.remove(profile)
        finishTransition(generation)
        connectionState = .unpaired
        hasResolvedLaunchState = true
        return true
    }

    func teardown() async {
        if case .tornDown(let generation) = phase {
            await waitForTransition(generation)
            return
        }
        let generation = await beginTransition(final: true)
        guard case .tornDown(let currentGeneration) = phase,
              currentGeneration == generation else { return }
        connectionState = .unpaired
        hasResolvedLaunchState = true
    }

    func noteDisconnected(connectionID deliveredConnectionID: Int?) {
        guard admitsEvent(connectionID: deliveredConnectionID) else { return }
        connectionID = nil
    }

    func requestReconnect(immediate: Bool = false, replaceExisting: Bool = false) {
        guard phase.admitsWork, profiles.selected != nil else { return }
        if replaceExisting, reconnectTask != nil {
            guard reconnectCanBeAccelerated else { return }
            cancelReconnect()
        }
        guard reconnectTask == nil else { return }
        connectionState = .reconnecting
        scheduleReconnect(immediate: immediate)
    }

    func waitForConnected(
        until deadline: ContinuousClock.Instant,
        admission: Admission
    ) async -> Bool {
        while clock.now() < deadline {
            guard !Task.isCancelled, admitsGeneration(admission.generation) else { return false }
            if connectionState == .connected { return true }
            if connectionState == .unauthorized || connectionState == .unpaired { return false }
            if reconnectTask == nil { scheduleReconnect(immediate: true) }
            do { try await clock.sleep(.milliseconds(100)) }
            catch { return false }
        }
        return false
    }

    #if HOSTED_TEST
    private var hostedProfileID: String?

    func connectHosted(profile: GatewayProfile, token: String) async throws {
        guard let admission else { throw CancellationError() }
        let connection = try await client.connectForLifecycle(profile: profile, token: token)
        try require(admission)
        connectionID = connection.id
        try await client.activateEvents(connectionID: connection.id)
        let connectedAdmission = Admission(
            generation: admission.generation,
            connectionID: connection.id
        )
        try require(connectedAdmission)
        hostedProfileID = profile.id
        gatewayInfo = connection.info
        connectionState = .connected
    }
    #endif

    private var isTornDown: Bool {
        if case .tornDown = phase { return true }
        return false
    }

    private func admitsGeneration(_ generation: Int) -> Bool {
        phase.admitsWork && phase.generation == generation
    }

    private func requireGeneration(_ generation: Int) throws {
        try Task.checkCancellation()
        guard admitsGeneration(generation) else { throw CancellationError() }
    }

    private func performPair(_ invitation: PairingInvitation, attemptID: UUID) async throws {
        connectionState = .connecting
        let name = UIDevice.current.name
        let (profile, token) = try await pairer.pair(invitation, deviceName: name)
        try requirePairingAttempt(attemptID)
        try pairingCommit(profile, token)
        // Credential commit is the point of no return. The lifecycle must leave
        // transition state even when the presenting task is cancelled afterward.
        let generation = await beginTransition(invalidatePairing: false)
        guard phase.generation == generation,
              pairingAttempt?.id == attemptID else { throw CancellationError() }
        finishTransition(generation)
        if Task.isCancelled {
            continueCommittedConnection(profile: profile, token: token, generation: generation)
            throw CancellationError()
        }
        await connect(
            profile: profile,
            token: token,
            pairingAttemptID: attemptID,
            admission: Admission(generation: generation, connectionID: nil)
        )
        try requirePairingAttempt(attemptID)
        try requireGeneration(generation)
        hasResolvedLaunchState = true
    }

    private func requirePairingAttempt(_ id: UUID) throws {
        try Task.checkCancellation()
        guard pairingAttempt?.id == id else { throw CancellationError() }
    }

    private func invalidatePairingAttempt() {
        let task = pairingAttempt?.task
        pairingAttempt = nil
        task?.cancel()
    }

    @discardableResult
    private func beginTransition(
        final: Bool = false,
        invalidatePairing: Bool = true
    ) async -> Int {
        let generation = phase.generation &+ 1
        phase = final ? .tornDown(generation) : .transitioning(generation)
        if invalidatePairing { invalidatePairingAttempt() }

        let precedingTransition = transitionTask
        let reconnect = reconnectTask
        let committedConnection = committedConnectionTask
        let foreground = foregroundReconciliationTask
        reconnectTask = nil
        committedConnectionTask = nil
        reconnectAttemptGeneration &+= 1
        reconnectCanBeAccelerated = false
        foregroundReconciliationTask = nil
        foregroundReconciliationGeneration &+= 1
        reconnect?.cancel()
        committedConnection?.cancel()
        foreground?.cancel()
        gatewayInfo = nil
        connectionID = nil

        let transition = Task { @MainActor [weak self] in
            await precedingTransition?.value
            guard let self else { return }
            await self.delegate?.lifecycleRetireProjection(final: final)
            await self.client.close()
            await reconnect?.value
            await committedConnection?.value
            await foreground?.value
            self.completeTransition(generation)
        }
        transitionTask = transition
        await transition.value
        return generation
    }

    private func waitForTransition(_ generation: Int) async {
        guard completedTransitionGeneration < generation else { return }
        await withCheckedContinuation { continuation in
            transitionWaiters[generation, default: []].append(continuation)
        }
    }

    private func completeTransition(_ generation: Int) {
        completedTransitionGeneration = max(completedTransitionGeneration, generation)
        let completed = transitionWaiters.keys.filter { $0 <= generation }
        for key in completed {
            let waiters = transitionWaiters.removeValue(forKey: key) ?? []
            for waiter in waiters { waiter.resume() }
        }
    }

    private func finishTransition(_ generation: Int) {
        guard case .transitioning(let currentGeneration) = phase,
              currentGeneration == generation else { return }
        phase = .active(generation)
    }

    private func connect(
        profile: GatewayProfile,
        token: String,
        pairingAttemptID: UUID? = nil,
        admission: Admission
    ) async {
        guard admits(admission) else { return }
        connectionState = .connecting
        do {
            let connection = try await client.connectForLifecycle(profile: profile, token: token)
            try require(admission)
            if let pairingAttemptID { try requirePairingAttempt(pairingAttemptID) }
            connectionID = connection.id
            try await client.activateEvents(connectionID: connection.id)
            let connectedAdmission = Admission(
                generation: admission.generation,
                connectionID: connection.id
            )
            try require(connectedAdmission)
            gatewayInfo = connection.info
            delegate?.lifecycleInvalidateSessionConnectionOwnership()
            async let refresh: Void = delegate?.lifecycleRefreshAll(admission: connectedAdmission) ?? ()
            async let restore: Void = delegate?.lifecycleRestoreMountedPresentation(admission: connectedAdmission) ?? ()
            async let terminals: Void = delegate?.lifecycleReattachTerminals(admission: connectedAdmission) ?? ()
            _ = await (refresh, restore, terminals)
            try require(connectedAdmission)
            if let pairingAttemptID { try requirePairingAttempt(pairingAttemptID) }
            connectionState = .connected
            cancelReconnect()
        } catch {
            guard admitsGeneration(admission.generation) else { return }
            if let pairingAttemptID, (try? requirePairingAttempt(pairingAttemptID)) == nil { return }
            if let failure = error as? GatewayFailure, failure.code == "unauthenticated" {
                connectionState = .unauthorized
                delegate?.lifecycleSurface(failure)
            } else if error is CancellationError {
                if pairingAttemptID != nil {
                    continueCommittedConnection(
                        profile: profile,
                        token: token,
                        generation: admission.generation
                    )
                }
            } else {
                connectionState = .offline(error.localizedDescription)
                scheduleReconnect()
            }
        }
    }

    private func continueCommittedConnection(
        profile: GatewayProfile,
        token: String,
        generation: Int
    ) {
        guard admitsGeneration(generation), committedConnectionTask == nil else { return }
        connectionState = .reconnecting
        committedConnectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.connect(
                profile: profile,
                token: token,
                admission: Admission(generation: generation, connectionID: nil)
            )
            if self.phase.generation == generation {
                self.hasResolvedLaunchState = true
                self.committedConnectionTask = nil
            }
        }
    }

    private func cancelReconnect() {
        let task = reconnectTask
        reconnectTask = nil
        reconnectAttemptGeneration &+= 1
        reconnectCanBeAccelerated = false
        task?.cancel()
    }

    private func admitsReconnect(lifecycleGeneration: Int, attemptGeneration: Int) -> Bool {
        admitsGeneration(lifecycleGeneration) && reconnectAttemptGeneration == attemptGeneration
    }

    private func requireReconnect(lifecycleGeneration: Int, attemptGeneration: Int) throws {
        try Task.checkCancellation()
        guard admitsReconnect(
            lifecycleGeneration: lifecycleGeneration,
            attemptGeneration: attemptGeneration
        ) else { throw CancellationError() }
    }

    private func finishReconnect(lifecycleGeneration: Int, attemptGeneration: Int) {
        guard admitsReconnect(
            lifecycleGeneration: lifecycleGeneration,
            attemptGeneration: attemptGeneration
        ) else { return }
        reconnectTask = nil
        reconnectCanBeAccelerated = false
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard phase.admitsWork, profiles.selected != nil, reconnectTask == nil else { return }
        let lifecycleGeneration = phase.generation
        reconnectAttemptGeneration &+= 1
        let attemptGeneration = reconnectAttemptGeneration
        let clock = self.clock
        let delayPolicy = reconnectDelayPolicy
        reconnectCanBeAccelerated = !immediate
        reconnectTask = Task { [weak self] in
            do {
                if !immediate {
                    try await clock.sleep(delayPolicy.delay(nominalSeconds: delayPolicy.initialSeconds))
                    guard let self, self.admitsReconnect(
                        lifecycleGeneration: lifecycleGeneration,
                        attemptGeneration: attemptGeneration
                    ) else { return }
                    self.reconnectCanBeAccelerated = false
                }
                var nominalDelay = delayPolicy.initialSeconds
                while !Task.isCancelled {
                    guard let self, self.admitsReconnect(
                        lifecycleGeneration: lifecycleGeneration,
                        attemptGeneration: attemptGeneration
                    ) else { return }
                    self.connectionState = .reconnecting
                    do {
                        let connection = try await self.client.reconnectForLifecycle()
                        try self.requireReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        self.connectionID = connection.id
                        try await self.client.activateEvents(connectionID: connection.id)
                        try self.requireReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        let admission = Admission(
                            generation: lifecycleGeneration,
                            connectionID: connection.id
                        )
                        self.gatewayInfo = connection.info
                        self.delegate?.lifecycleInvalidateSessionConnectionOwnership()
                        async let refresh: Void = self.delegate?.lifecycleRefreshAll(admission: admission) ?? ()
                        await self.delegate?.lifecycleRestoreMountedPresentation(admission: admission)
                        await self.delegate?.lifecycleReattachTerminals(admission: admission)
                        _ = await refresh
                        try self.requireReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        self.connectionState = .connected
                        self.finishReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        return
                    } catch let failure as GatewayFailure where failure.code == "unauthenticated" {
                        guard !Task.isCancelled, self.admitsReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        ) else { return }
                        self.connectionState = .unauthorized
                        self.delegate?.lifecycleSurface(failure)
                        self.finishReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        return
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled, self.admitsReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        ) else { return }
                        self.connectionState = .offline(error.localizedDescription)
                        self.reconnectCanBeAccelerated = true
                        try await clock.sleep(delayPolicy.delay(nominalSeconds: nominalDelay))
                        guard self.admitsReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        ) else { return }
                        self.reconnectCanBeAccelerated = false
                        nominalDelay = delayPolicy.nextNominalSeconds(after: nominalDelay)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }
}
