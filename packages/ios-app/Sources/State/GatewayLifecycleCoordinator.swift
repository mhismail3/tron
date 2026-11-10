import Foundation
import Observation
import TronMobileCore
import UIKit

enum GatewayConnectionState: Equatable {
    case unpaired, connecting, connected, reconnecting, restarting, unauthorized, offline(String)
}

typealias GatewayPairingCommit = @MainActor @Sendable (GatewayProfile, String) throws -> Void
typealias GatewayProfileTokenLookup = @MainActor @Sendable (GatewayProfile) throws -> String?

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

    static let parkedRetryBound = Duration.seconds(30)

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
    @ObservationIgnored let recorder: GatewayConnectionEpisodeRecorder

    weak var delegate: (any GatewayLifecycleProjectionDelegate)?

    private(set) var connectionState: GatewayConnectionState = .unpaired
    private(set) var hasResolvedLaunchState = false
    private(set) var gatewayInfo: GatewayInfo?
    private(set) var connectionID: Int?
    private var activatedConnectionID: Int?

    private var phase: Phase = .active(0)
    var currentLifecycleGeneration: Int { phase.generation }
    private var completedTransitionGeneration = 0
    private var transitionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var transitionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var parkedRetryTask: Task<Void, Never>?
    private var parkedRetryGeneration = 0
    private var lastReconnectRefusalReason: String?
    private var committedConnectionTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttemptInFlightLoop: String?
    @ObservationIgnored private var reconnectLoopID: String?
    private var connectionAdmissionTask: Task<Void, Never>?
    private var connectionAdmissionGeneration = 0
    private var reconnectAttemptGeneration = 0
    private var reconnectCanBeAccelerated = false
    @ObservationIgnored private var reconnectPathChangedDuringAttempt = false
    private var restartRequested = false
    private var restartWatchdogTask: Task<Void, Never>?
    private var pairingAttempt: PairingAttempt?
    private var foregroundReconciliationTask: Task<Void, Never>?
    private var deferredProjectionTask: Task<Void, Never>?
    private var deferredProjectionAdmission: Admission?
    private var foregroundReconciliationGeneration = 0
    private var backgroundRetirementTask: Task<Void, Never>?
    private var sceneIsBackgrounded = false
    private var projectionFailureGeneration: Int?
    private var nonRetryableRecoveryFailure = false
    private var networkPathSatisfied = true
    private var networkPathSignature: String?
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
        profileTokenLookup: @escaping GatewayProfileTokenLookup,
        appLog: AppLog = .shared,
        networkInterfaces: @escaping @Sendable () -> String? = { GatewayNetworkPathSnapshot.shared.current },
        watchdogClock: MonotonicClock = .continuous
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
        self.recorder = GatewayConnectionEpisodeRecorder(
            clock: clock,
            appLog: appLog,
            watchdogClock: watchdogClock,
            networkInterfaces: networkInterfaces
        )
        self.recorder.stallGuard = { [weak self] in
            guard let self else { return nil }
            return self.reconnectStallGuard
        }
    }

    var reconnectStallGuard: GatewayReconnectStallGuard? {
        if reconnectLoopID != nil, reconnectAttemptInFlightLoop == reconnectLoopID { return nil }
        if reconnectTask != nil, reconnectCanBeAccelerated { return nil }
        if parkedRetryTask != nil { return nil }
        if !networkPathSatisfied { return .pathUnsatisfied }
        if nonRetryableRecoveryFailure { return .nonRetryable }
        if connectionAdmissionTask != nil { return .connectionAdmissionTask }
        if committedConnectionTask != nil { return .committedConnectionTask }
        if reconnectTask != nil { return .reconnectTaskBusy }
        return .other
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

    private enum TokenRead {
        case token(String)
        case missing
        case unreadable(Error)
    }

    static let unreadableTokenReason = "This iPhone's Keychain cannot be read yet. Unlock it to reconnect."

    private func readToken(_ profile: GatewayProfile) -> TokenRead {
        do {
            guard let token = try profileTokenLookup(profile) else { return .missing }
            return .token(token)
        } catch {
            return .unreadable(error)
        }
    }

    func start() async {
        guard phase.admitsWork, !sceneIsBackgrounded,
              connectionAdmissionTask == nil,
              committedConnectionTask == nil,
              reconnectTask == nil,
              connectionState != .connecting,
              connectionState != .connected,
              connectionState != .reconnecting else { return }
        guard let profile = profiles.selected else {
            connectionState = .unpaired
            hasResolvedLaunchState = true
            return
        }
        let token: String
        switch readToken(profile) {
        case .token(let stored): token = stored
        case .missing:
            connectionState = .unpaired
            hasResolvedLaunchState = true
            return
        case .unreadable:
            connectionState = .offline(Self.unreadableTokenReason)
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
                self.requestReconnect(immediate: true, replaceExisting: true, ignoresPathHint: true)
            }
        }
        guard connectionAdmissionTask == nil, committedConnectionTask == nil else { return nil }
        guard connectionState == .connected else {
            switch connectionState {
            case .offline, .reconnecting, .restarting:
                guard !nonRetryableRecoveryFailure else { return nil }
                requestReconnect(immediate: true, replaceExisting: true, ignoresPathHint: true)
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

    @discardableResult
    func requestTransportRecovery() -> Task<Void, Never>? {
        guard phase.admitsWork, !sceneIsBackgrounded else { return nil }
        guard backgroundRetirementTask == nil,
              connectionAdmissionTask == nil,
              committedConnectionTask == nil else { return nil }
        switch connectionState {
        case .offline, .reconnecting, .restarting:
            guard !nonRetryableRecoveryFailure else { return nil }
            requestReconnect(immediate: true, replaceExisting: true)
            return reconnectTask
        case .unpaired, .unauthorized, .connecting, .connected:
            return nil
        }
    }

    func enteredBackground() {
        recorder.endEpisode(.background)
        let backgroundConnectionID = connectionID
        foregroundReconciliationGeneration &+= 1
        let task = foregroundReconciliationTask
        foregroundReconciliationTask = nil
        task?.cancel()
        let reconnect = reconnectTask
        reconnectTask = nil
        reconnectAttemptGeneration &+= 1
        reconnectCanBeAccelerated = false
        reconnectPathChangedDuringAttempt = false
        reconnectLoopID = nil
        reconnectAttemptInFlightLoop = nil
        reconnect?.cancel()
        cancelParkedRetry()
        let committed = committedConnectionTask
        committedConnectionTask = nil
        committed?.cancel()
        let initial = connectionAdmissionTask
        connectionAdmissionTask = nil
        connectionAdmissionGeneration &+= 1
        initial?.cancel()
        cancelDeferredProjection()
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
            if pairingAttempt?.id == attemptID {
                pairingAttempt = nil
                parkUnsatisfiedPathWhenIdle()
            }
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
        let token: String
        switch readToken(profile) {
        case .token(let stored): token = stored
        case .unreadable(let error):
            finishTransition(generation)
            connectionState = .offline(Self.unreadableTokenReason)
            hasResolvedLaunchState = true
            delegate?.lifecycleSurface(error)
            return
        case .missing:
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
            admission: Admission(generation: generation, connectionID: nil)
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
        let code = GatewayDiagnosticFailure.normalizedCode(reason)
        recorder.noteDisconnected(
            profileID: profiles.selected?.id,
            lifecycleGeneration: phase.generation,
            foreground: !sceneIsBackgrounded,
            cause: countsAsTransportFailure ? code : "restart"
        )
        cancelDeferredProjection()
        if countsAsTransportFailure {
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

    func notePathHint(satisfied: Bool, signature: String? = nil) {
        let pathChanged = networkPathSatisfied != satisfied
            || (signature != nil && signature != networkPathSignature)
        networkPathSatisfied = satisfied
        if let signature { networkPathSignature = signature }
        guard phase.admitsWork, !sceneIsBackgrounded else { return }
        guard satisfied else {
            if connectionID == nil {
                cancelReconnect()
                parkRecovery(reason: "pathUnsatisfied")
            }
            return
        }
        guard !nonRetryableRecoveryFailure, connectionAdmissionTask == nil, committedConnectionTask == nil else { return }
        switch connectionState {
        case .offline, .reconnecting, .restarting: break
        case .unpaired, .unauthorized, .connecting, .connected: return
        }
        if reconnectTask != nil, reconnectCanBeAccelerated {
            if pathChanged { reconnectSchedule.restartForPathChange() } else { reconnectSchedule.accelerate() }
            return
        }
        if reconnectTask != nil {
            if pathChanged {
                reconnectPathChangedDuringAttempt = true
                reconnectSchedule.restartForPathChange()
            }
            return
        }
        if pathChanged { reconnectSchedule.reset() }
        requestReconnect(immediate: true, replaceExisting: false)
    }

    func requestReconnect(
        immediate: Bool = false,
        replaceExisting: Bool = false,
        ignoresPathHint: Bool = false
    ) {
        guard phase.admitsWork, !sceneIsBackgrounded else {
            recordReconnectRefusal("scene-retired")
            return
        }
        if nonRetryableRecoveryFailure {
            recordReconnectRefusal("nonRetryable")
            return
        }
        guard profiles.selected != nil else {
            recordReconnectRefusal("unpaired")
            return
        }
        if connectionAdmissionTask != nil {
            recordReconnectRefusal("connectionAdmissionTask")
            return
        }
        if committedConnectionTask != nil {
            recordReconnectRefusal("committedConnectionTask")
            return
        }
        guard networkPathSatisfied || ignoresPathHint else {
            if connectionID == nil { parkRecovery(reason: "pathUnsatisfied") }
            return
        }
        if replaceExisting, reconnectTask != nil {
            guard reconnectCanBeAccelerated else {
                recordReconnectRefusal("reconnectTaskInFlight")
                return
            }
            cancelReconnect()
        }
        guard reconnectTask == nil else {
            recordReconnectRefusal("reconnectTaskScheduled")
            return
        }
        activatedConnectionID = nil
        connectionState = restartRequested ? .restarting : .reconnecting
        scheduleReconnect(immediate: immediate, ignoresPathHint: ignoresPathHint)
    }

    func retryReconnect() {
        guard phase.admitsWork, !sceneIsBackgrounded,
              reconnectTask == nil || reconnectCanBeAccelerated,
              connectionAdmissionTask == nil,
              committedConnectionTask == nil,
              foregroundReconciliationTask == nil,
              deferredProjectionTask == nil,
              backgroundRetirementTask == nil,
              let profile = profiles.selected, case .token(let token) = readToken(profile) else { return }
        nonRetryableRecoveryFailure = false
        if reconnectTask != nil, reconnectCanBeAccelerated {
            reconnectSchedule.accelerate()
            return
        }
        cancelReconnect()
        continueCommittedConnection(profile: profile, token: token, generation: phase.generation)
    }

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
        reconnectPathChangedDuringAttempt = false
        reconnectLoopID = nil
        reconnectAttemptInFlightLoop = nil
        foregroundReconciliationTask = nil
        deferredProjectionTask = nil
        cancelDeferredProjection()
        backgroundRetirementTask = nil
        foregroundReconciliationGeneration &+= 1
        cancelParkedRetry()
        recorder.endEpisode(.stopped)
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
        admission: Admission
    ) async {
        guard admits(admission), connectionAdmissionTask == nil else { return }
        connectionAdmissionGeneration &+= 1
        let admissionGeneration = connectionAdmissionGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.delegate?.lifecycleLoadCache(profileID: profile.id, admission: admission)
            guard !Task.isCancelled, self.admits(admission),
                  self.connectionAdmissionGeneration == admissionGeneration else { return }
            await self.connect(
                profile: profile, token: token, admission: admission
            )
        }
        connectionAdmissionTask = task
        await task.value
        guard connectionAdmissionGeneration == admissionGeneration else { return }
        connectionAdmissionTask = nil
        parkUnsatisfiedPathWhenIdle()
        guard admitsGeneration(admission.generation) else { return }
        hasResolvedLaunchState = true
    }

    private func connect(
        profile: GatewayProfile,
        token: String,
        pairingAttemptID: UUID? = nil,
        admission: Admission
    ) async {
        guard admits(admission) else { return }
        let connectAttemptGeneration = connectionAdmissionGeneration
        let failurePresentationGeneration = connectionFailureClassifier.beginAttempt()
        activatedConnectionID = nil
        connectionState = .connecting
        let attemptStartedAt = clock.now()
        let diagnosticSequence = await client.latestDiagnosticSequence()
        guard admits(admission),
              connectionAdmissionGeneration == connectAttemptGeneration,
              connectionState == .connecting else { return }
        var establishedConnectionID: Int?
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
            recordAttempt(
                attemptID: "initial", retry: 0, startedAt: attemptStartedAt, delayBeforeMs: 0,
                stageReached: "connected", reason: nil, succeeded: true,
                gatewayConnectionID: connection.gatewayConnectionID, connectionID: connection.id
            )
            restartWatchdogTask?.cancel()
            restartWatchdogTask = nil
            restartRequested = false
            delegate?.lifecycleInvalidateSessionConnectionOwnership()
            delegate?.lifecycleBeginReconciliationAggregate(admission: connectedAdmission)
            cancelParkedRetry()
            cancelReconnect()
            beginDeferredProjection(admission: connectedAdmission)
        } catch {
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
                recordAttempt(
                    attemptID: "initial",
                    retry: 0, startedAt: attemptStartedAt, delayBeforeMs: 0,
                    stageReached: Self.attemptStage(
                        diagnostic: nil, establishedConnection: establishedConnectionID != nil,
                        code: GatewayDiagnosticFailure.answerCode(error),
                    ),
                    reason: GatewayDiagnosticFailure.answerCode(error), succeeded: false,
                    connectionID: establishedConnectionID
                )
                recorder.endEpisode(.stopped)
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
                recordAttempt(
                    attemptID: "initial",
                    retry: 0, startedAt: attemptStartedAt, delayBeforeMs: 0,
                    stageReached: Self.attemptStage(
                        diagnostic: nil, establishedConnection: establishedConnectionID != nil,
                        code: GatewayDiagnosticFailure.answerCode(error),
                    ),
                    reason: GatewayDiagnosticFailure.answerCode(error), succeeded: false,
                    connectionID: establishedConnectionID
                )
                recorder.endEpisode(.stopped)
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
                recordAttempt(
                    attemptID: "initial",
                    retry: 0, startedAt: attemptStartedAt, delayBeforeMs: 0,
                    stageReached: Self.attemptStage(
                        diagnostic: diagnostic, establishedConnection: establishedConnectionID != nil,
                        code: GatewayDiagnosticFailure.answerCode(error),
                    ),
                    reason: GatewayDiagnosticFailure.answerCode(error), succeeded: false,
                    connectionID: establishedConnectionID,
                    diagnostic: diagnostic
                )
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

    private func beginDeferredProjection(admission: Admission) {
        cancelDeferredProjection()
        deferredProjectionAdmission = admission
        deferredProjectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            async let refresh: Void = self.delegate?.lifecycleRefreshAll(admission: admission) ?? ()
            async let restore = self.delegate?.lifecycleRestoreMountedPresentation(admission: admission) ?? true
            let (_, restored) = await (refresh, restore)
            guard !Task.isCancelled, self.admits(admission) else { return }
            let activeConnectionID = await self.client.activeConnectionID()
            guard !Task.isCancelled, self.admits(admission) else { return }
            guard activeConnectionID == admission.connectionID else {
                self.deferredProjectionAdmission = nil
                self.delegate?.lifecycleCompleteReconciliationAggregate(
                    admission: admission,
                    succeeded: false
                )
                self.deferredProjectionTask = nil
                self.requestReconnect(immediate: true)
                return
            }
            let succeeded = restored && self.projectionFailureGeneration != admission.generation
            self.projectionFailureGeneration = nil
            self.deferredProjectionAdmission = nil
            self.delegate?.lifecycleCompleteReconciliationAggregate(
                admission: admission,
                succeeded: succeeded
            )
            self.deferredProjectionTask = nil
        }
    }

    private func cancelDeferredProjection() {
        deferredProjectionTask?.cancel()
        deferredProjectionTask = nil
        guard let admission = deferredProjectionAdmission else { return }
        deferredProjectionAdmission = nil
        delegate?.lifecycleCompleteReconciliationAggregate(
            admission: admission,
            succeeded: false
        )
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
                self.parkUnsatisfiedPathWhenIdle()
            }
        }
    }

    private func cancelReconnect() {
        reconnectSchedule.cancel()
        let task = reconnectTask
        reconnectTask = nil
        reconnectAttemptGeneration &+= 1
        reconnectCanBeAccelerated = false
        reconnectPathChangedDuringAttempt = false
        reconnectLoopID = nil
        reconnectAttemptInFlightLoop = nil
        task?.cancel()
    }

    private func parkRecovery(reason: String) {
        guard phase.admitsWork, !sceneIsBackgrounded, !nonRetryableRecoveryFailure,
              profiles.selected != nil, parkedRetryTask == nil else { return }
        guard connectionAdmissionTask == nil, committedConnectionTask == nil,
              pairingAttempt == nil else { return }
        switch connectionState {
        case .offline, .unpaired, .unauthorized: return
        case .connected, .connecting, .reconnecting, .restarting: break
        }
        connectionState = restartRequested ? .restarting : .reconnecting
        parkedRetryGeneration &+= 1
        let generation = parkedRetryGeneration
        let clock = self.clock
        parkedRetryTask = Task { @MainActor [weak self] in
            try? await clock.sleep(Self.parkedRetryBound)
            guard let self, !Task.isCancelled,
                  self.parkedRetryGeneration == generation else { return }
            self.parkedRetryTask = nil
            self.delegate?.lifecycleRecordDiagnostic(
                event: "reconnect.parked-resume",
                message: "reason=\(reason) boundMs=\(diagnosticMilliseconds(Self.parkedRetryBound))"
            )
            self.requestReconnect(immediate: true, ignoresPathHint: true)
        }
        delegate?.lifecycleRecordDiagnostic(
            event: "reconnect.parked",
            message: "reason=\(reason) boundMs=\(diagnosticMilliseconds(Self.parkedRetryBound))"
        )
    }

    private func cancelParkedRetry() {
        parkedRetryGeneration &+= 1
        parkedRetryTask?.cancel()
        parkedRetryTask = nil
    }

    private func parkUnsatisfiedPathWhenIdle() {
        guard connectionID == nil, !networkPathSatisfied, reconnectTask == nil else { return }
        parkRecovery(reason: "pathUnsatisfied")
    }

    private func recordReconnectRefusal(_ reason: String) {
        guard lastReconnectRefusalReason != reason else { return }
        lastReconnectRefusalReason = reason
        delegate?.lifecycleRecordDiagnostic(event: "reconnect.skipped", message: "reason=\(reason)")
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
        reconnectPathChangedDuringAttempt = false
        reconnectLoopID = nil
        reconnectAttemptInFlightLoop = nil
    }

    private static func attemptStage(
        diagnostic: GatewayConnectionDiagnostic?,
        establishedConnection: Bool,
        code: String
    ) -> String {
        if let diagnostic { return diagnostic.stage.rawValue }
        if establishedConnection { return GatewayConnectionDiagnosticStage.helloReceive.rawValue }
        switch code {
        case "timeout", "transport", "disconnected", "possibly_sent":
            return GatewayConnectionDiagnosticStage.transportOpen.rawValue
        case "cancelled":
            return "admission"
        default:
            return GatewayConnectionDiagnosticStage.helloSend.rawValue
        }
    }

    private func recordAttempt(
        attemptID: String,
        retry: Int,
        startedAt: ContinuousClock.Instant,
        delayBeforeMs: Int,
        stageReached: String,
        reason: String?,
        succeeded: Bool,
        gatewayConnectionID: String? = nil,
        connectionID: Int?,
        diagnostic: GatewayConnectionDiagnostic? = nil
    ) {
        recorder.recordAttempt(GatewayConnectionAttempt(
            owner: .selected,
            profileID: profiles.selected?.id,
            lifecycleGeneration: phase.generation,
            connectionID: connectionID,
            attemptID: attemptID,
            retry: retry,
            stageReached: stageReached,
            reason: reason,
            interfaces: diagnostic?.handshake?.networkInterfaces,
            pathSatisfied: networkPathSatisfied,
            foreground: !sceneIsBackgrounded,
            delayBeforeMs: delayBeforeMs,
            startedAt: startedAt,
            gatewayConnectionID: gatewayConnectionID,
            succeeded: succeeded
        ))
    }

    private func scheduleReconnect(immediate: Bool = false, ignoresPathHint: Bool = false) {
        guard phase.admitsWork, !sceneIsBackgrounded else {
            recordReconnectRefusal("scene-retired")
            return
        }
        guard networkPathSatisfied || ignoresPathHint else {
            parkRecovery(reason: "pathUnsatisfied")
            return
        }
        guard !nonRetryableRecoveryFailure else {
            recordReconnectRefusal("nonRetryable")
            return
        }
        guard profiles.selected != nil else {
            recordReconnectRefusal("unpaired")
            return
        }
        guard reconnectTask == nil else {
            recordReconnectRefusal("reconnectTaskScheduled")
            return
        }
        lastReconnectRefusalReason = nil
        cancelParkedRetry()
        let lifecycleGeneration = phase.generation
        reconnectAttemptGeneration &+= 1
        let attemptGeneration = reconnectAttemptGeneration
        let clock = self.clock
        let delayPolicy = reconnectDelayPolicy
        let reconnectSchedule = self.reconnectSchedule!
        reconnectCanBeAccelerated = !immediate
        reconnectPathChangedDuringAttempt = false
        var pathHintRequired = !ignoresPathHint
        let loopID = UUID().uuidString
        reconnectLoopID = loopID
        let initialDelay: Duration = immediate ? .zero : .seconds(delayPolicy.initialSeconds)
        let scheduledAt = clock.now()
        delegate?.lifecycleRecordDiagnostic(
            event: "reconnect.scheduled",
            message: "immediate=\(immediate) attempt=\(attemptGeneration) lifecycle=\(lifecycleGeneration) loop=\(loopID) scheduledDelayMs=\(diagnosticMilliseconds(initialDelay)) cause=\(restartRequested ? "restart" : "connection-unavailable")"
        )
        reconnectTask = Task { [weak self] in
            defer {
                if let self, self.reconnectAttemptInFlightLoop == loopID {
                    self.reconnectAttemptInFlightLoop = nil
                }
            }
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
                    guard self.networkPathSatisfied || !pathHintRequired else {
                        self.finishReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        self.parkRecovery(reason: "pathUnsatisfied")
                        return
                    }
                    pathHintRequired = true
                    self.connectionState = self.restartRequested ? .restarting : .reconnecting
                    retry += 1
                    let startedAt = clock.now()
                    self.reconnectAttemptInFlightLoop = loopID
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
                    let tokenRead = self.profiles.selected.map { self.readToken($0) } ?? .missing
                    guard let profile = self.profiles.selected, case .token(let token) = tokenRead else {
                        if case .unreadable = tokenRead {
                            self.connectionState = .offline(Self.unreadableTokenReason)
                        } else {
                            self.connectionState = .unpaired
                        }
                        self.hasResolvedLaunchState = true
                        self.finishReconnect(lifecycleGeneration: lifecycleGeneration, attemptGeneration: attemptGeneration)
                        return
                    }
                    do {
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
                        self.restartWatchdogTask?.cancel()
                        self.restartWatchdogTask = nil
                        self.restartRequested = false
                        self.connectionState = .connected
                        self.connectionFailureClassifier.reset()
                        self.hasResolvedLaunchState = true
                        self.delegate?.lifecycleRecordDiagnostic(event: "reconnect.connected",
                            message: "attempt=\(attemptGeneration) loop=\(loopID) retry=\(retry) connectionID=\(connection.id) gatewayConnectionId=\(connection.gatewayConnectionID ?? "unknown") handshakeMs=\(diagnosticMilliseconds(startedAt.duration(to: clock.now())))")
                        self.recordAttempt(
                            attemptID: loopID, retry: retry, startedAt: startedAt,
                            delayBeforeMs: diagnosticMilliseconds(delayStartedAt.duration(to: startedAt)),
                            stageReached: "connected", reason: nil, succeeded: true,
                            gatewayConnectionID: connection.gatewayConnectionID,
                            connectionID: connection.id
                        )
                        self.reconnectAttemptInFlightLoop = nil
                        self.delegate?.lifecycleBeginReconciliationAggregate(admission: admission)
                        self.delegate?.lifecycleInvalidateSessionConnectionOwnership()
                        self.beginDeferredProjection(admission: admission)
                        self.finishReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        return
                    } catch let failure as GatewayFailure where failure.code == "unauthenticated" {
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
                        self.recordAttempt(
                            attemptID: loopID,
                            retry: retry, startedAt: startedAt,
                            delayBeforeMs: diagnosticMilliseconds(delayStartedAt.duration(to: startedAt)),
                            stageReached: Self.attemptStage(
                                diagnostic: nil, establishedConnection: establishedConnectionID != nil,
                                code: "unauthenticated"
                            ),
                            reason: "unauthenticated", succeeded: false,
                            connectionID: establishedConnectionID
                        )
                        self.recorder.endEpisode(.stopped)
                        self.delegate?.lifecycleRecordDiagnostic(event: "reconnect.failure",
                            message: "attempt=\(attemptGeneration) loop=\(loopID) retry=\(retry) code=unauthenticated durationMs=\(diagnosticMilliseconds(startedAt.duration(to: clock.now())))")
                        self.delegate?.lifecycleSurface(failure)
                        self.finishReconnect(
                            lifecycleGeneration: lifecycleGeneration,
                            attemptGeneration: attemptGeneration
                        )
                        return
                    } catch is CancellationError {
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
                        self.recordAttempt(
                            attemptID: loopID,
                            retry: retry, startedAt: startedAt,
                            delayBeforeMs: diagnosticMilliseconds(delayStartedAt.duration(to: startedAt)),
                            stageReached: Self.attemptStage(
                                diagnostic: nil, establishedConnection: establishedConnectionID != nil,
                                code: GatewayDiagnosticFailure.answerCode(failure),
                                    ),
                            reason: GatewayDiagnosticFailure.answerCode(failure), succeeded: false,
                            connectionID: establishedConnectionID
                        )
                        self.recorder.endEpisode(.stopped)
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
                        self.recordAttempt(
                            attemptID: loopID,
                            retry: retry, startedAt: startedAt,
                            delayBeforeMs: diagnosticMilliseconds(delayStartedAt.duration(to: startedAt)),
                            stageReached: Self.attemptStage(
                                diagnostic: diagnostic, establishedConnection: establishedConnectionID != nil,
                                code: GatewayDiagnosticFailure.answerCode(error),
                                    ),
                            reason: GatewayDiagnosticFailure.answerCode(error), succeeded: false,
                            connectionID: establishedConnectionID,
                            diagnostic: diagnostic
                        )
                        self.reconnectAttemptInFlightLoop = nil
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
                            self.parkRecovery(reason: "pathUnsatisfied")
                            return
                        }
                        self.reconnectCanBeAccelerated = true
                        delayStartedAt = clock.now()
                        if self.reconnectPathChangedDuringAttempt {
                            self.reconnectPathChangedDuringAttempt = false
                            self.delegate?.lifecycleRecordDiagnostic(event: "reconnect.delay",
                                message: "attempt=\(attemptGeneration) loop=\(loopID) retry=\(retry + 1) cause=pathChanged")
                            continue
                        }
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
