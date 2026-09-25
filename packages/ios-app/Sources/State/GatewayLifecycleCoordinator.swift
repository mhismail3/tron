import Foundation
import Observation
import UIKit

enum GatewayConnectionState: Equatable {
    case unpaired, connecting, connected, reconnecting, restarting, unauthorized, offline(String)
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
    func lifecycleBeginReconciliationAggregate(admission: GatewayLifecycleCoordinator.Admission)
    func lifecycleCompleteReconciliationAggregate(
        admission: GatewayLifecycleCoordinator.Admission,
        succeeded: Bool
    )
    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async
    func lifecycleRestoreMountedPresentation(admission: GatewayLifecycleCoordinator.Admission) async -> Bool
    func lifecycleReattachTerminals(admission: GatewayLifecycleCoordinator.Admission) async
    func lifecycleReconcileForeground(admission: GatewayLifecycleCoordinator.Admission) async throws
    func lifecycleRetireProjection(final: Bool) async
    func lifecycleSurface(_ error: Error)
    func lifecycleRecordDiagnostic(event: String, message: String)
    func lifecycleConnectionFailurePresentationDidChange()
}

extension GatewayLifecycleProjectionDelegate {
    func lifecycleRecordDiagnostic(event: String, message: String) {}
    func lifecycleConnectionFailurePresentationDidChange() {}
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
    @ObservationIgnored private var reconnectSchedule: GatewayReconnectSchedule!
    private let uuidSource: UUIDSource
    private let pairer: GatewayPairer
    private let pairingCommit: GatewayPairingCommit
    private let pairingCommitWithoutSelection: GatewayPairingCommit?
    private let profileTokenLookup: GatewayProfileTokenLookup

    weak var delegate: (any GatewayLifecycleProjectionDelegate)?

    private(set) var connectionState: GatewayConnectionState = .unpaired
    private(set) var hasResolvedLaunchState = false
    private(set) var gatewayInfo: GatewayInfo?
    private(set) var connectionID: Int?
    /// The exact socket whose receive/event delivery loop has been activated.
    /// `connectionID` is installed slightly earlier so the first buffered event
    /// can be admitted; route work must wait for this stronger boundary.
    private var activatedConnectionID: Int?

    private var phase: Phase = .active(0)
    var currentLifecycleGeneration: Int { phase.generation }
    private var completedTransitionGeneration = 0
    private var transitionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var transitionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var committedConnectionTask: Task<Void, Never>?
    /// Covers initial connect as well as replacement entrypoints. Path and
    /// foreground hints may accelerate this owner, never create a peer socket.
    private var connectionAdmissionTask: Task<Void, Never>?
    private var connectionAdmissionGeneration = 0
    private var reconnectAttemptGeneration = 0
    private var reconnectCanBeAccelerated = false
    private var restartRequested = false
    private var restartWatchdogTask: Task<Void, Never>?
    private var pairingAttempt: PairingAttempt?
    private var foregroundReconciliationTask: Task<Void, Never>?
    /// Projection refresh/restoration may continue after transport readiness
    /// for profile switches so dashboard navigation can hand ChatView an
    /// admitted route without waiting on unrelated slow work.
    private var deferredProjectionTask: Task<Void, Never>?
    private var foregroundReconciliationGeneration = 0
    private var backgroundRetirementTask: Task<Void, Never>?
    private var sceneIsBackgrounded = false
    private var projectionFailureGeneration: Int?
    private var nonRetryableRecoveryFailure = false
    private var networkPathSatisfied = true
    private var connectionFailureClassifier = GatewayConnectionFailureClassifier()

    var noPathPresentation: GatewayNoPathPresentation? { connectionFailureClassifier.noPath }

    init(
        client: GatewayClient,
        profiles: GatewayProfileStore,
        clock: MonotonicClock,
        reconnectDelayPolicy: ReconnectDelayPolicy,
        uuidSource: UUIDSource,
        pairer: GatewayPairer,
        pairingCommit: @escaping GatewayPairingCommit,
        pairingCommitWithoutSelection: GatewayPairingCommit? = nil,
        profileTokenLookup: @escaping GatewayProfileTokenLookup
    ) {
        self.client = client
        self.profiles = profiles
        self.clock = clock
        self.reconnectDelayPolicy = reconnectDelayPolicy
        self.reconnectSchedule = GatewayReconnectSchedule(clock: clock, delayPolicy: reconnectDelayPolicy)
        self.uuidSource = uuidSource
        self.pairer = pairer
        self.pairingCommit = pairingCommit
        self.pairingCommitWithoutSelection = pairingCommitWithoutSelection
        self.profileTokenLookup = profileTokenLookup
    }

    var admission: Admission? {
        guard phase.admitsWork, !sceneIsBackgrounded else { return nil }
        return Admission(generation: phase.generation, connectionID: connectionID)
    }

    var generationAdmission: Admission? {
        guard phase.admitsWork, !sceneIsBackgrounded else { return nil }
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

    var admitsWork: Bool { phase.admitsWork && !sceneIsBackgrounded }
    /// Foreground routing must not start until an already-scheduled background
    /// socket retirement has finished and queued its replacement reconnect.
    var routeActivationRequiresRetirementBarrier: Bool { backgroundRetirementTask != nil }

    func admits(_ admission: Admission) -> Bool {
        guard phase.admitsWork, !sceneIsBackgrounded, phase.generation == admission.generation else { return false }
        guard let expectedConnectionID = admission.connectionID else { return true }
        return connectionID == expectedConnectionID
    }

    func admitsEvent(connectionID deliveredConnectionID: Int?) -> Bool {
        guard phase.admitsWork, !sceneIsBackgrounded else { return false }
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
        guard phase.admitsWork, !sceneIsBackgrounded,
              connectionAdmissionTask == nil,
              committedConnectionTask == nil,
              reconnectTask == nil,
              connectionState != .connecting,
              connectionState != .connected,
              connectionState != .reconnecting else { return }
        guard let profile = profiles.selected, let token = profileTokenLookup(profile) else {
            connectionState = .unpaired
            hasResolvedLaunchState = true
            return
        }
        await loadCacheAndConnect(
            profile: profile, token: token,
            admission: Admission(generation: phase.generation, connectionID: nil)
        )
    }

    @discardableResult
    func becameActive() -> Task<Void, Never>? {
        guard phase.admitsWork else { return nil }
        delegate?.lifecycleRecordDiagnostic(event: "scene.foreground", message: "scene=foreground")
        sceneIsBackgrounded = false
        if let backgroundRetirementTask {
            let generation = phase.generation
            let activationGeneration = foregroundReconciliationGeneration
            return Task { @MainActor [weak self] in
                await backgroundRetirementTask.value
                guard let self,
                      self.phase.admitsWork,
                      self.phase.generation == generation,
                      self.foregroundReconciliationGeneration == activationGeneration else { return }
                self.backgroundRetirementTask = nil
                self.requestReconnect(immediate: true, replaceExisting: true)
            }
        }
        guard connectionAdmissionTask == nil, committedConnectionTask == nil else { return nil }
        guard connectionState == .connected else {
            switch connectionState {
            case .offline, .reconnecting, .restarting:
                guard !nonRetryableRecoveryFailure else { return nil }
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

    /// A suspended app cannot service the shared event stream reliably. Retire
    /// the transport epoch before suspension, discard its queued deliveries, and
    /// let the next active scene perform one authoritative reconnect.
    func enteredBackground() {
        delegate?.lifecycleRecordDiagnostic(event: "scene.background", message: "scene=background")
        let backgroundConnectionID = connectionID
        foregroundReconciliationGeneration &+= 1
        let task = foregroundReconciliationTask
        foregroundReconciliationTask = nil
        task?.cancel()
        let reconnect = reconnectTask
        reconnectTask = nil
        reconnectAttemptGeneration &+= 1
        reconnectCanBeAccelerated = false
        reconnect?.cancel()
        let committed = committedConnectionTask
        committedConnectionTask = nil
        committed?.cancel()
        let initial = connectionAdmissionTask
        connectionAdmissionTask = nil
        connectionAdmissionGeneration &+= 1
        initial?.cancel()
        deferredProjectionTask?.cancel()
        deferredProjectionTask = nil
        delegate?.lifecycleInvalidateSessionConnectionOwnership()
        connectionID = nil
        activatedConnectionID = nil
        sceneIsBackgrounded = true
        guard phase.admitsWork else { return }
        let previousRetirement = backgroundRetirementTask
        let retirement = Task { @MainActor [weak self] in
            await previousRetirement?.value
            guard !Task.isCancelled, let self else { return }
            _ = backgroundConnectionID
            await self.client.retireForBackground()
        }
        backgroundRetirementTask = retirement
    }

    func pair(_ invitation: PairingInvitation, selectingProfile: Bool = true) async throws {
        guard phase.admitsWork else { throw CancellationError() }
        let previousConnectionState = pairingAttempt?.previousConnectionState ?? connectionState
        invalidatePairingAttempt()
        let lifecycleGeneration = phase.generation
        let attemptID = uuidSource.next()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performPair(
                invitation,
                attemptID: attemptID,
                selectingProfile: selectingProfile,
                previousConnectionState: previousConnectionState
            )
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
        do {
            try profiles.select(profile)
        } catch {
            finishTransition(generation)
            connectionState = .offline(error.localizedDescription)
            hasResolvedLaunchState = true
            delegate?.lifecycleSurface(error)
            return
        }
        finishTransition(generation)
        await loadCacheAndConnect(
            profile: profile, token: token,
            admission: Admission(generation: generation, connectionID: nil),
            awaitProjection: false
        )
    }

    @discardableResult
    func forgetCurrentGateway() async -> Bool {
        guard !isTornDown else { return false }
        let generation = await beginTransition()
        guard phase.generation == generation else { return false }
        if let profile = profiles.selected {
            do { try profiles.remove(profile) }
            catch {
                finishTransition(generation)
                connectionState = .offline(error.localizedDescription)
                hasResolvedLaunchState = true
                delegate?.lifecycleSurface(error)
                return false
            }
        }
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
        do { try profiles.remove(profile) }
        catch {
            finishTransition(generation)
            connectionState = .offline(error.localizedDescription)
            hasResolvedLaunchState = true
            delegate?.lifecycleSurface(error)
            return false
        }
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

    func noteDisconnected(
        connectionID deliveredConnectionID: Int?,
        reason: String = "disconnected",
        countsAsTransportFailure: Bool = true
    ) async {
        guard admitsEvent(connectionID: deliveredConnectionID) else { return }
        if countsAsTransportFailure {
            let code = GatewayDiagnosticFailure.normalizedCode(reason)
            connectionFailureClassifier.failedAttempt(nil, code: code)
            delegate?.lifecycleConnectionFailurePresentationDidChange()
            delegate?.lifecycleRecordDiagnostic(event: "reconnect.failure", message: "code=\(code)")
        }
        if activatedConnectionID == deliveredConnectionID || deliveredConnectionID == nil {
            activatedConnectionID = nil
        }
        connectionID = nil
    }

    func beginRestarting() {
        guard phase.admitsWork, !sceneIsBackgrounded, !restartRequested else { return }
        restartRequested = true
        connectionState = .restarting
        restartWatchdogTask?.cancel()
        let generation = phase.generation
        restartWatchdogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(.seconds(90))
            guard !Task.isCancelled,
                  self.phase.generation == generation,
                  self.restartRequested else { return }
            self.restartRequested = false
            self.connectionState = .reconnecting
            self.requestReconnect(immediate: true, replaceExisting: true)
        }
    }

    /// Path hints only gate replacement attempts. They never establish endpoint
    /// reachability or revoke a currently viable socket. A satisfied hint may
    /// revive a parked episode even when the missed callback left no task.
    func notePathHint(satisfied: Bool) {
        networkPathSatisfied = satisfied
        guard phase.admitsWork, !sceneIsBackgrounded else { return }
        guard satisfied else {
            if connectionID == nil { cancelReconnect() }
            return
        }
        guard !nonRetryableRecoveryFailure, connectionAdmissionTask == nil, committedConnectionTask == nil else { return }
        // NWPathMonitor can deliver before startup or pairing. A path hint may
        // revive recovery, but cannot bypass initial profile/cache admission or
        // turn an unpaired/unauthorized selection into a transport failure.
        switch connectionState {
        case .offline, .reconnecting, .restarting: break
        case .unpaired, .unauthorized, .connecting, .connected: return
        }
        if reconnectTask != nil, reconnectCanBeAccelerated {
            reconnectSchedule.accelerate()
            return
        }
        guard reconnectTask == nil else { return }
        requestReconnect(immediate: true, replaceExisting: false)
    }

    func requestReconnect(immediate: Bool = false, replaceExisting: Bool = false) {
        guard phase.admitsWork, !sceneIsBackgrounded, networkPathSatisfied,
              !nonRetryableRecoveryFailure, profiles.selected != nil,
              connectionAdmissionTask == nil, committedConnectionTask == nil else { return }
        if replaceExisting, reconnectTask != nil {
            guard reconnectCanBeAccelerated else { return }
            cancelReconnect()
        }
        guard reconnectTask == nil else { return }
        activatedConnectionID = nil
        connectionState = restartRequested ? .restarting : .reconnecting
        scheduleReconnect(immediate: immediate)
    }

    /// Explicit user retry clears a nonretryable stop and reconnects only the
    /// selected profile. Transport mutations and receipt ownership never call it.
    func retryReconnect() {
        guard phase.admitsWork, !sceneIsBackgrounded,
              reconnectTask == nil || reconnectCanBeAccelerated,
              connectionAdmissionTask == nil,
              committedConnectionTask == nil,
              foregroundReconciliationTask == nil,
              deferredProjectionTask == nil,
              backgroundRetirementTask == nil,
              let profile = profiles.selected, let token = profileTokenLookup(profile) else { return }
        nonRetryableRecoveryFailure = false
        if reconnectTask != nil, reconnectCanBeAccelerated {
            reconnectSchedule.accelerate()
            return
        }
        cancelReconnect()
        // A stopped profile switch may never have configured this client's
        // endpoint. Rebind the exact selected profile, not its previous socket.
        continueCommittedConnection(profile: profile, token: token, generation: phase.generation)
    }

    /// Waits only for an exact activated transport on the requested profile.
    /// Unlike public `.connected` readiness, this does not wait for dashboard,
    /// settings, device, terminal, or mounted-presentation reconciliation.
    /// Notification routing uses this narrow boundary before `session.open`.
    func waitForRouteConnection(
        profileID: String,
        until deadline: ContinuousClock.Instant,
        admission: Admission
    ) async -> Admission? {
        while clock.now() < deadline {
            guard !Task.isCancelled,
                  admitsGeneration(admission.generation),
                  selectedProfileID == profileID else { return nil }
            if let activatedConnectionID,
               connectionID == activatedConnectionID {
                let activeConnectionID = await client.activeConnectionID()
                guard !Task.isCancelled,
                      admitsGeneration(admission.generation),
                      selectedProfileID == profileID else { return nil }
                if activeConnectionID == activatedConnectionID {
                    return Admission(
                        generation: admission.generation,
                        connectionID: activatedConnectionID
                    )
                }
                self.activatedConnectionID = nil
                if connectionID == activatedConnectionID { connectionID = nil }
                connectionState = .reconnecting
            }
            switch connectionState {
            case .unpaired, .unauthorized:
                return nil
            case .offline, .reconnecting, .restarting, .connected:
                if reconnectTask == nil, committedConnectionTask == nil {
                    requestReconnect(immediate: true)
                }
            case .connecting:
                break
            }
            do { try await clock.sleep(.milliseconds(100)) }
            catch { return nil }
        }
        return nil
    }

    func waitForConnected(
        until deadline: ContinuousClock.Instant,
        admission: Admission
    ) async -> Bool {
        while clock.now() < deadline {
            guard !Task.isCancelled, admitsGeneration(admission.generation) else { return false }
            if connectionState == .connected {
                let activeConnectionID = await client.activeConnectionID()
                guard !Task.isCancelled, admitsGeneration(admission.generation) else { return false }
                if let connectionID, activeConnectionID == connectionID { return true }
                // The client actor can observe transport death before its
                // MainActor event is reduced. Close that race synchronously so
                // a user mutation never receives a false connected admission.
                connectionID = nil
                connectionState = .reconnecting
            }
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
        activatedConnectionID = connection.id
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
        phase.admitsWork && !sceneIsBackgrounded && phase.generation == generation
    }

    private func requireGeneration(_ generation: Int) throws {
        try Task.checkCancellation()
        guard admitsGeneration(generation) else { throw CancellationError() }
    }

    private func performPair(
        _ invitation: PairingInvitation,
        attemptID: UUID,
        selectingProfile: Bool,
        previousConnectionState: GatewayConnectionState
    ) async throws {
        connectionState = .connecting
        let name = UIDevice.current.name
        let (profile, token) = try await pairer.pair(invitation, deviceName: name)
        try requirePairingAttempt(attemptID)
        if selectingProfile {
            try pairingCommit(profile, token)
        } else {
            guard let pairingCommitWithoutSelection else {
                throw GatewayFailure(
                    code: "pairing_mode_unavailable",
                    message: "This app cannot add another server without replacing the current connection.",
                    retryable: false,
                    details: nil
                )
            }
            try pairingCommitWithoutSelection(profile, token)
            connectionState = previousConnectionState
            return
        }
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
        let initialConnection = connectionAdmissionTask
        let foreground = foregroundReconciliationTask
        let deferredProjection = deferredProjectionTask
        let backgroundRetirement = backgroundRetirementTask
        reconnectTask = nil
        committedConnectionTask = nil
        connectionAdmissionTask = nil
        connectionAdmissionGeneration &+= 1
        reconnectAttemptGeneration &+= 1
        reconnectCanBeAccelerated = false
        foregroundReconciliationTask = nil
        deferredProjectionTask = nil
        backgroundRetirementTask = nil
        foregroundReconciliationGeneration &+= 1
        reconnect?.cancel()
        committedConnection?.cancel()
        initialConnection?.cancel()
        foreground?.cancel()
        deferredProjection?.cancel()
        gatewayInfo = nil
        connectionID = nil
        activatedConnectionID = nil
        projectionFailureGeneration = nil

        let transition = Task { @MainActor [weak self] in
            await precedingTransition?.value
            guard let self else { return }
            await self.delegate?.lifecycleRetireProjection(final: final)
            await deferredProjection?.value
            await backgroundRetirement?.value
            await self.client.close()
            await reconnect?.value
            await committedConnection?.value
            await initialConnection?.value
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

    private func loadCacheAndConnect(
        profile: GatewayProfile,
        token: String,
        admission: Admission,
        awaitProjection: Bool = true
    ) async {
        guard admits(admission), connectionAdmissionTask == nil else { return }
        connectionAdmissionGeneration &+= 1
        let admissionGeneration = connectionAdmissionGeneration
        // Claim the whole operation before cache I/O yields. Startup, path,
        // foreground, and profile-switch work must not create a peer hello.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.delegate?.lifecycleLoadCache(profileID: profile.id, admission: admission)
            guard !Task.isCancelled, self.admits(admission),
                  self.connectionAdmissionGeneration == admissionGeneration else { return }
            await self.connect(
                profile: profile, token: token, admission: admission,
                awaitProjection: awaitProjection
            )
        }
        connectionAdmissionTask = task
        await task.value
        guard connectionAdmissionGeneration == admissionGeneration else { return }
        connectionAdmissionTask = nil
        guard admitsGeneration(admission.generation) else { return }
        hasResolvedLaunchState = true
    }

    private func connect(
        profile: GatewayProfile,
        token: String,
        pairingAttemptID: UUID? = nil,
        admission: Admission,
        awaitProjection: Bool = true
    ) async {
        guard admits(admission) else { return }
        let connectAttemptGeneration = connectionAdmissionGeneration
        let failurePresentationGeneration = connectionFailureClassifier.beginAttempt()
        activatedConnectionID = nil
        connectionState = .connecting
        let diagnosticSequence = await client.latestDiagnosticSequence()
        guard admits(admission),
              connectionAdmissionGeneration == connectAttemptGeneration,
              connectionState == .connecting else { return }
        var establishedConnectionID: Int?
        var reconciliationAdmission: Admission?
        do {
            let connection = try await client.connectForLifecycle(profile: profile, token: token)
            establishedConnectionID = connection.id
            try require(admission)
            if let pairingAttemptID { try requirePairingAttempt(pairingAttemptID) }
            connectionID = connection.id
            try await client.activateEvents(connectionID: connection.id)
            activatedConnectionID = connection.id
            let connectedAdmission = Admission(
                generation: admission.generation,
                connectionID: connection.id
            )
            try require(connectedAdmission)
            gatewayInfo = connection.info
            reconnectSchedule.reset()
            nonRetryableRecoveryFailure = false
            connectionState = .connected
            connectionFailureClassifier.reset()
            restartWatchdogTask?.cancel()
            restartWatchdogTask = nil
            restartRequested = false
            delegate?.lifecycleInvalidateSessionConnectionOwnership()
            delegate?.lifecycleBeginReconciliationAggregate(admission: connectedAdmission)
            reconciliationAdmission = connectedAdmission
            if awaitProjection {
                async let refresh: Void = delegate?.lifecycleRefreshAll(admission: connectedAdmission) ?? ()
                async let restore = delegate?.lifecycleRestoreMountedPresentation(admission: connectedAdmission) ?? true
                async let terminals: Void = delegate?.lifecycleReattachTerminals(admission: connectedAdmission) ?? ()
                let (_, restored, _) = await (refresh, restore, terminals)
                let activeConnectionID = await client.activeConnectionID()
                try require(connectedAdmission)
                guard activeConnectionID == connection.id else {
                    throw GatewayFailure(code: "disconnected", message: "The Gateway connection closed during reconciliation.", retryable: true, details: nil)
                }
                let succeeded = restored && projectionFailureGeneration != admission.generation
                projectionFailureGeneration = nil
                delegate?.lifecycleCompleteReconciliationAggregate(
                    admission: connectedAdmission,
                    succeeded: succeeded
                )
                reconciliationAdmission = nil
                if !succeeded {
                    // Session projection failure is not transport failure. Keep
                    // the authenticated socket and expose the scoped Retry
                    // surface owned by the mounted presentation.
                    connectionState = .connected
                    if let pairingAttemptID { try requirePairingAttempt(pairingAttemptID) }
                    cancelReconnect()
                    return
                }
                if let pairingAttemptID { try requirePairingAttempt(pairingAttemptID) }
                cancelReconnect()
            } else {
                let projectionTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    async let refresh: Void = self.delegate?.lifecycleRefreshAll(admission: connectedAdmission) ?? ()
                    async let restore = self.delegate?.lifecycleRestoreMountedPresentation(admission: connectedAdmission) ?? true
                    async let terminals: Void = self.delegate?.lifecycleReattachTerminals(admission: connectedAdmission) ?? ()
                    let (_, restored, _) = await (refresh, restore, terminals)
                    let activeConnectionID = await self.client.activeConnectionID()
                    guard !Task.isCancelled, self.admits(connectedAdmission) else { return }
                    guard activeConnectionID == connectedAdmission.connectionID else {
                        self.connectionState = .offline("Gateway connection closed")
                        self.delegate?.lifecycleCompleteReconciliationAggregate(admission: connectedAdmission, succeeded: false)
                        self.deferredProjectionTask = nil
                        self.requestReconnect(immediate: true)
                        return
                    }
                    let succeeded = restored && self.projectionFailureGeneration != admission.generation
                    self.projectionFailureGeneration = nil
                    self.delegate?.lifecycleCompleteReconciliationAggregate(
                        admission: connectedAdmission,
                        succeeded: succeeded
                    )
                    // Projection failure leaves the live socket usable; only
                    // transport failure may recycle it.
                    self.connectionState = .connected
                    self.cancelReconnect()
                    self.deferredProjectionTask = nil
                }
                deferredProjectionTask = projectionTask
            }
        } catch {
            if let reconciliationAdmission {
                delegate?.lifecycleCompleteReconciliationAggregate(admission: reconciliationAdmission, succeeded: false)
            }
            if let establishedConnectionID {
                await client.closeIfCurrent(connectionID: establishedConnectionID)
                if activatedConnectionID == establishedConnectionID { activatedConnectionID = nil }
                if connectionID == establishedConnectionID { connectionID = nil }
            }
            guard admits(admission),
                  connectionAdmissionGeneration == connectAttemptGeneration,
                  connectionID == nil || connectionID == establishedConnectionID else { return }
            if Task.isCancelled, pairingAttemptID == nil { return }
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
            } else if GatewayRecoveryFailurePolicy.isNonRetryable(error) {
                nonRetryableRecoveryFailure = true
                connectionState = .offline(error.localizedDescription)
                delegate?.lifecycleRecordDiagnostic(
                    event: "reconnect.stopped",
                    message: "code=\(GatewayDiagnosticFailure.code(error)) nonRetryable=true"
                )
                delegate?.lifecycleSurface(error)
            } else {
                connectionState = .reconnecting
                delegate?.lifecycleRecordDiagnostic(
                    event: "reconnect.failure",
                    message: "code=\(GatewayDiagnosticFailure.code(error))"
                )
                let diagnostic = await client.latestHandshakeDiagnostic(after: diagnosticSequence)
                guard admits(admission),
                      connectionAdmissionGeneration == connectAttemptGeneration,
                      connectionState == .reconnecting else { return }
                if connectionFailureClassifier.failedAttempt(
                    diagnostic,
                    code: GatewayDiagnosticFailure.code(error),
                    attemptGeneration: failurePresentationGeneration
                ) {
                    delegate?.lifecycleConnectionFailurePresentationDidChange()
                }
                scheduleReconnect()
            }
        }
    }

    private func continueCommittedConnection(
        profile: GatewayProfile,
        token: String,
        generation: Int
    ) {
        guard admitsGeneration(generation),
              connectionAdmissionTask == nil,
              committedConnectionTask == nil,
              foregroundReconciliationTask == nil,
              deferredProjectionTask == nil,
              backgroundRetirementTask == nil else { return }
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
        reconnectSchedule.cancel()
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
        guard phase.admitsWork, !sceneIsBackgrounded, networkPathSatisfied,
              !nonRetryableRecoveryFailure, profiles.selected != nil,
              reconnectTask == nil else { return }
        let lifecycleGeneration = phase.generation
        reconnectAttemptGeneration &+= 1
        let attemptGeneration = reconnectAttemptGeneration
        let clock = self.clock
        let delayPolicy = reconnectDelayPolicy
        let reconnectSchedule = self.reconnectSchedule!
        reconnectCanBeAccelerated = !immediate
        let loopID = UUID().uuidString
        let initialDelay: Duration = immediate ? .zero : .seconds(delayPolicy.initialSeconds)
        let scheduledAt = clock.now()
        delegate?.lifecycleRecordDiagnostic(
            event: "reconnect.scheduled",
            message: "immediate=\(immediate) attempt=\(attemptGeneration) lifecycle=\(lifecycleGeneration) loop=\(loopID) scheduledDelayMs=\(diagnosticMilliseconds(initialDelay)) cause=\(restartRequested ? "restart" : "connection-unavailable")"
        )
        reconnectTask = Task { [weak self] in
            var retry = 0
            var delayStartedAt = scheduledAt
            do {
                if !immediate {
                    guard await reconnectSchedule.afterFailure(),
                          let self, self.admitsReconnect(
                        lifecycleGeneration: lifecycleGeneration,
                        attemptGeneration: attemptGeneration
                    ) else { return }
                    self.reconnectCanBeAccelerated = false
                }
                while !Task.isCancelled {
                    guard let self, self.admitsReconnect(
                        lifecycleGeneration: lifecycleGeneration,
                        attemptGeneration: attemptGeneration
                    ) else { return }
                    // A path can become unsatisfied while the predecessor socket
                    // is still active. Once that attempt retires, park until the
                    // next path callback instead of retrying on a known-down route.
                    guard self.networkPathSatisfied else {
                        self.finishReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        return
                    }
                    self.connectionState = self.restartRequested ? .restarting : .reconnecting
                    retry += 1
                    let startedAt = clock.now()
                    self.delegate?.lifecycleRecordDiagnostic(
                        event: "reconnect.attempt",
                        message: "attempt=\(attemptGeneration) loop=\(loopID) retry=\(retry) actualDelayMs=\(diagnosticMilliseconds(delayStartedAt.duration(to: startedAt))) state=\(self.restartRequested ? "restarting" : "reconnecting")"
                    )
                    let failurePresentationGeneration = self.connectionFailureClassifier.beginAttempt()
                    let connectionStateAtAttempt = self.connectionState
                    let diagnosticSequence = await self.client.latestDiagnosticSequence()
                    guard self.admitsReconnect(
                        lifecycleGeneration: lifecycleGeneration,
                        attemptGeneration: attemptGeneration
                    ), self.connectionState == connectionStateAtAttempt else { return }
                    var establishedConnectionID: Int?
                    var reconciliationAggregateAdmission: Admission?
                    guard let profile = self.profiles.selected,
                          let token = self.profileTokenLookup(profile) else {
                        self.connectionState = .unpaired
                        self.hasResolvedLaunchState = true
                        self.finishReconnect(lifecycleGeneration: lifecycleGeneration, attemptGeneration: attemptGeneration)
                        return
                    }
                    do {
                        // Background may retire startup before its first hello
                        // configured the client. The lifecycle's selected profile
                        // owns replacement credentials, not a predecessor socket.
                        let connection = try await self.client.reconnectForLifecycle(
                            profile: profile, token: token, attemptID: loopID
                        )
                        establishedConnectionID = connection.id
                        try self.requireReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        self.connectionID = connection.id
                        try await self.client.activateEvents(connectionID: connection.id)
                        self.activatedConnectionID = connection.id
                        try self.requireReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        guard self.connectionID == connection.id else {
                            throw GatewayFailure(
                                code: "disconnected",
                                message: "The Gateway connection ended during reconnect.",
                                retryable: true,
                                details: nil
                            )
                        }
                        let admission = Admission(
                            generation: lifecycleGeneration,
                            connectionID: connection.id
                        )
                        self.gatewayInfo = connection.info
                        reconnectSchedule.reset()
                        // Authenticated handshake plus event activation is the
                        // connection boundary, including after system.stopping.
                        // Projection owners reconcile beneath this usable socket;
                        // slow or failed projection work cannot strand a healthy
                        // replacement in Restarting.
                        self.restartWatchdogTask?.cancel()
                        self.restartWatchdogTask = nil
                        self.restartRequested = false
                        self.connectionState = .connected
                        self.connectionFailureClassifier.reset()
                        self.hasResolvedLaunchState = true
                        self.delegate?.lifecycleRecordDiagnostic(event: "reconnect.connected",
                            message: "attempt=\(attemptGeneration) loop=\(loopID) retry=\(retry) connectionID=\(connection.id) handshakeMs=\(diagnosticMilliseconds(startedAt.duration(to: clock.now())))")
                        reconciliationAggregateAdmission = admission
                        self.delegate?.lifecycleBeginReconciliationAggregate(admission: admission)
                        self.delegate?.lifecycleInvalidateSessionConnectionOwnership()
                        // Until the mounted authority and transport proof have
                        // both returned, do not publish a connected state that
                        // a dead replacement socket could leave behind.
                        self.connectionState = .reconnecting
                        async let refresh: Void = self.delegate?.lifecycleRefreshAll(admission: admission) ?? ()
                        let restored = await self.delegate?.lifecycleRestoreMountedPresentation(admission: admission) ?? true
                        guard restored else {
                            // The optional owner must settle before this
                            // async-let scope exits, but AppModel's owner
                            // returns before its own optional reads finish.
                            _ = await refresh
                            // The event reducer can lag transport retirement.
                            // Consult the client before publishing readiness,
                            // then revalidate lifecycle ownership after the await.
                            self.connectionState = .reconnecting
                            let activeConnectionID = await self.client.activeConnectionID()
                            try self.requireReconnect(
                                lifecycleGeneration: lifecycleGeneration,
                                attemptGeneration: attemptGeneration
                            )
                            guard self.connectionID == connection.id,
                                  activeConnectionID == connection.id else {
                                throw GatewayFailure(
                                    code: "disconnected",
                                    message: "The Gateway connection ended during refresh.",
                                    retryable: true,
                                    details: nil
                                )
                            }
                            // Publish the verified live transport before the
                            // projection owner chooses its scoped recovery UI.
                            self.connectionState = .connected
                            self.delegate?.lifecycleCompleteReconciliationAggregate(
                                admission: admission,
                                succeeded: false
                            )
                            reconciliationAggregateAdmission = nil
                            self.restartWatchdogTask?.cancel()
                            self.restartWatchdogTask = nil
                            self.restartRequested = false
                            self.finishReconnect(
                                lifecycleGeneration: lifecycleGeneration,
                                attemptGeneration: attemptGeneration
                            )
                            return
                        }
                        self.connectionState = .connected
                        await self.delegate?.lifecycleReattachTerminals(admission: admission)
                        _ = await refresh
                        self.connectionState = .reconnecting
                        let activeConnectionID = await self.client.activeConnectionID()
                        try self.requireReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        guard self.connectionID == connection.id,
                              activeConnectionID == connection.id else {
                            throw GatewayFailure(
                                code: "disconnected",
                                message: "The Gateway connection ended during refresh.",
                                retryable: true,
                                details: nil
                            )
                        }
                        if self.projectionFailureGeneration == lifecycleGeneration {
                            self.delegate?.lifecycleCompleteReconciliationAggregate(
                                admission: admission,
                                succeeded: false
                            )
                            reconciliationAggregateAdmission = nil
                            self.projectionFailureGeneration = nil
                            self.restartWatchdogTask?.cancel()
                            self.restartWatchdogTask = nil
                            self.restartRequested = false
                            self.connectionState = .connected
                            self.finishReconnect(
                                lifecycleGeneration: lifecycleGeneration,
                                attemptGeneration: attemptGeneration
                            )
                            return
                        }
                        self.restartWatchdogTask?.cancel()
                        self.restartWatchdogTask = nil
                        self.restartRequested = false
                        self.connectionState = .connected
                        self.delegate?.lifecycleCompleteReconciliationAggregate(
                            admission: admission,
                            succeeded: true
                        )
                        reconciliationAggregateAdmission = nil
                        self.restartRequested = false
                        self.finishReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        return
                    } catch let failure as GatewayFailure where failure.code == "unauthenticated" {
                        if let reconciliationAggregateAdmission {
                            self.delegate?.lifecycleCompleteReconciliationAggregate(
                                admission: reconciliationAggregateAdmission,
                                succeeded: false
                            )
                        }
                        if let establishedConnectionID {
                            await self.client.closeIfCurrent(connectionID: establishedConnectionID)
                            if self.activatedConnectionID == establishedConnectionID { self.activatedConnectionID = nil }
                            if self.connectionID == establishedConnectionID { self.connectionID = nil }
                        }
                        guard !Task.isCancelled, self.admitsReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        ) else { return }
                        self.restartWatchdogTask?.cancel()
                        self.restartWatchdogTask = nil
                        self.restartRequested = false
                        self.connectionState = .unauthorized
                        self.delegate?.lifecycleRecordDiagnostic(event: "reconnect.failure",
                            message: "attempt=\(attemptGeneration) loop=\(loopID) retry=\(retry) code=unauthenticated durationMs=\(diagnosticMilliseconds(startedAt.duration(to: clock.now())))")
                        self.delegate?.lifecycleSurface(failure)
                        self.finishReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        return
                    } catch is CancellationError {
                        if let reconciliationAggregateAdmission {
                            self.delegate?.lifecycleCompleteReconciliationAggregate(
                                admission: reconciliationAggregateAdmission,
                                succeeded: false
                            )
                        }
                        if let establishedConnectionID {
                            await self.client.closeIfCurrent(connectionID: establishedConnectionID)
                            if self.activatedConnectionID == establishedConnectionID { self.activatedConnectionID = nil }
                            if self.connectionID == establishedConnectionID { self.connectionID = nil }
                        }
                        if self.phase.admitsWork,
                           self.connectionID == establishedConnectionID {
                            self.connectionState = .reconnecting
                        }
                        guard !Task.isCancelled, self.admitsReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        ) else { return }
                        self.reconnectCanBeAccelerated = true
                        self.scheduleReconnect(immediate: true)
                        return
                    } catch let failure where GatewayRecoveryFailurePolicy.isNonRetryable(failure) {
                        if let reconciliationAggregateAdmission {
                            self.delegate?.lifecycleCompleteReconciliationAggregate(
                                admission: reconciliationAggregateAdmission,
                                succeeded: false
                            )
                        }
                        if let establishedConnectionID {
                            await self.client.closeIfCurrent(connectionID: establishedConnectionID)
                            if self.activatedConnectionID == establishedConnectionID { self.activatedConnectionID = nil }
                            if self.connectionID == establishedConnectionID { self.connectionID = nil }
                        }
                        guard !Task.isCancelled, self.admitsReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        ) else { return }
                        self.restartWatchdogTask?.cancel()
                        self.restartWatchdogTask = nil
                        self.restartRequested = false
                        self.nonRetryableRecoveryFailure = true
                        self.connectionState = .offline(failure.localizedDescription)
                        self.delegate?.lifecycleRecordDiagnostic(
                            event: "reconnect.stopped",
                            message: "attempt=\(attemptGeneration) loop=\(loopID) retry=\(retry) code=\(GatewayDiagnosticFailure.code(failure)) nonRetryable=true"
                        )
                        self.finishReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        return
                    } catch {
                        if let reconciliationAggregateAdmission {
                            self.delegate?.lifecycleCompleteReconciliationAggregate(
                                admission: reconciliationAggregateAdmission,
                                succeeded: false
                            )
                        }
                        if let establishedConnectionID {
                            await self.client.closeIfCurrent(connectionID: establishedConnectionID)
                            if self.activatedConnectionID == establishedConnectionID { self.activatedConnectionID = nil }
                            if self.connectionID == establishedConnectionID { self.connectionID = nil }
                        }
                        guard !Task.isCancelled, self.admitsReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        ) else { return }
                        let failedState: GatewayConnectionState = self.restartRequested ? .restarting : .reconnecting
                        self.connectionState = failedState
                        self.delegate?.lifecycleRecordDiagnostic(
                            event: "reconnect.failure",
                            message: "attempt=\(attemptGeneration) loop=\(loopID) retry=\(retry) code=\(GatewayDiagnosticFailure.code(error)) durationMs=\(diagnosticMilliseconds(startedAt.duration(to: clock.now())))"
                        )
                        let diagnostic = await self.client.latestHandshakeDiagnostic(after: diagnosticSequence)
                        guard self.admitsReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        ), self.connectionState == failedState else { return }
                        if self.connectionFailureClassifier.failedAttempt(
                            diagnostic,
                            code: GatewayDiagnosticFailure.code(error),
                            attemptGeneration: failurePresentationGeneration
                        ) {
                            self.delegate?.lifecycleConnectionFailurePresentationDidChange()
                        }
                        guard self.networkPathSatisfied else {
                            self.finishReconnect(
                                lifecycleGeneration: lifecycleGeneration,
                                attemptGeneration: attemptGeneration
                            )
                            return
                        }
                        self.reconnectCanBeAccelerated = true
                        delayStartedAt = clock.now()
                        self.delegate?.lifecycleRecordDiagnostic(event: "reconnect.delay",
                            message: "attempt=\(attemptGeneration) loop=\(loopID) retry=\(retry + 1)")
                        guard await reconnectSchedule.afterFailure(),
                              self.admitsReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        ) else { return }
                        self.reconnectCanBeAccelerated = false
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
