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

    /// A parked episode — foreground, disconnected, with nothing in flight or
    /// scheduled because the last path hint said unsatisfied — resumes after
    /// this bound even when the next path callback and the next foreground
    /// activation never arrive. The bound exists because a missed callback was
    /// one of the 2026-09-27 silent gaps; 30 s is short enough that the phone is
    /// never quiet for long and far longer than one backoff interval, so a
    /// healthy loop never reaches it.
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
    /// Phone connection records: one `gateway.attempt` per attempt, one
    /// `connection.episode` per outage, plus the stall/main-actor watchdogs.
    @ObservationIgnored let recorder: GatewayConnectionEpisodeRecorder

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
    /// The bound that resumes recovery parked by an unsatisfied path hint.
    private var parkedRetryTask: Task<Void, Never>?
    private var parkedRetryGeneration = 0
    /// One `reconnect.skipped` record per refusal cause: a 100 ms readiness
    /// poll that cannot schedule must not write a record every iteration.
    private var lastReconnectRefusalReason: String?
    private var committedConnectionTask: Task<Void, Never>?
    /// The loop whose transport attempt is in flight, or `nil` while none is.
    /// It is an identity, not a flag: a cancelled predecessor must not clear the
    /// marker its replacement set.
    @ObservationIgnored private var reconnectAttemptInFlightLoop: String?
    /// The loop `reconnectTask` currently owns, so only the live loop's marker
    /// is consulted and a retired loop cannot park the watchdog at `nil`.
    @ObservationIgnored private var reconnectLoopID: String?
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
    /// The admission the deferred projection is reconciling, while its task
    /// exists. Cancelling the projection settles this admission, because a
    /// cancelled task publishes no result of its own.
    private var deferredProjectionAdmission: Admission?
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
            // Watchdog ticks never ride the injected lifecycle clock: a test
            // that drives the timeline manually must not have to service them.
            watchdogClock: watchdogClock,
            networkInterfaces: networkInterfaces
        )
        // `self` must be unwrapped first: folding `self?.reconnectStallGuard`
        // into one optional would turn the 'recovery is progressing' nil into
        // `other` and report a stall whenever an episode is open.
        self.recorder.stallGuard = { [weak self] in
            guard let self else { return nil }
            return self.reconnectStallGuard
        }
    }

    /// Why no attempt is in flight or scheduled, for the stall watchdog. `nil`
    /// means recovery is progressing: an attempt is running, waiting in its
    /// bounded backoff, or already scheduled by the parked bound. A parked
    /// episode is therefore named by `reconnect.parked`, never as a stall.
    var reconnectStallGuard: GatewayReconnectStallGuard? {
        if reconnectLoopID != nil, reconnectAttemptInFlightLoop == reconnectLoopID { return nil }
        if reconnectTask != nil, reconnectCanBeAccelerated { return nil }
        // An unsatisfied path hint parks the loop, but `parkRecovery` schedules
        // the attempt that probes it, so recovery is still on a timeline.
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
                // Foreground is the app's own proof that it just woke: probe the
                // possibly stale path hint rather than parking again (C-1).
                self.requestReconnect(immediate: true, replaceExisting: true, ignoresPathHint: true)
            }
        }
        guard connectionAdmissionTask == nil, committedConnectionTask == nil else { return nil }
        guard connectionState == .connected else {
            switch connectionState {
            case .offline, .reconnecting, .restarting:
                guard !nonRetryableRecoveryFailure else { return nil }
                // Foreground is the app's own proof that it just woke: a path
                // hint that still reads unsatisfied is stale, and no further
                // callback is coming while the scene is already active, so the
                // parked episode resumes with one probe attempt (C-1).
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

    /// A transport-only recovery request from a caller that saw one request fail
    /// but did not move the scene (the workspace browser's transient retry). It
    /// mirrors `becameActive()`'s non-scene branch exactly: it revives a parked
    /// `offline`/`reconnecting`/`restarting` route and does nothing else. A
    /// rejected credential is not retried, a live socket is not replaced, and
    /// foreground reconciliation never runs, so a failed read cannot change
    /// reconnect behaviour.
    @discardableResult
    func requestTransportRecovery() -> Task<Void, Never>? {
        guard phase.admitsWork, !sceneIsBackgrounded else { return nil }
        // A background retirement barrier owns the next socket; a read failure
        // must not start a peer while the old epoch is still retiring.
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

    /// A suspended app cannot service the shared event stream reliably. Retire
    /// the transport epoch before suspension, discard its queued deliveries, and
    /// let the next active scene perform one authoritative reconnect.
    func enteredBackground() {
        // A backgrounded app parks recovery; the episode it was explaining ends
        // here, so no episode record ever spans a suspension. The episode keeps
        // its own profile: a selection change is not this transition.
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
                // A pairing that ended without a socket (its connect failed on a
                // known-down route) parks the stale hint like the other attempt
                // owners do: foreground and disconnected is still on a timeline.
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
        // Every admitted loss opens the episode, whether or not it counts as a
        // transport failure: a Gateway restart is a loss too, and the gap from it
        // to the first reconnect has to be measurable. A restart whose first
        // reconnect succeeds would otherwise leave no episode at all. The
        // episode carries the loss's own code as its cause, so a disconnect
        // whose first reconnect succeeds still names what ended the connection
        // instead of reporting `causes=none`.
        recorder.noteDisconnected(
            profileID: profiles.selected?.id,
            lifecycleGeneration: phase.generation,
            foreground: !sceneIsBackgrounded,
            cause: countsAsTransportFailure ? code : "restart"
        )
        // The projection that ran beneath the lost socket belongs to it: cancel
        // it so its late result cannot publish over the replacement and settle
        // its reconciliation aggregate, and let the event owner's request start
        // the next attempt at once instead of waiting for restoration the dead
        // socket no longer admits.
        cancelDeferredProjection()
        if countsAsTransportFailure {
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
    /// revive a parked episode even when the missed callback left no task, and an
    /// unsatisfied one arms the bound that probes the path without a callback.
    func notePathHint(satisfied: Bool) {
        networkPathSatisfied = satisfied
        guard phase.admitsWork, !sceneIsBackgrounded else { return }
        guard satisfied else {
            if connectionID == nil {
                cancelReconnect()
                parkRecovery(reason: "pathUnsatisfied")
            }
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
            // The satisfied notice is this owner's only path signal: cancel the
            // pending wait so the loop attempts at once, and restart the curve
            // so the route that just came back is not delayed by the wait the
            // route that went away had grown (C-3). Failures that see no path
            // notice keep the capped, jittered curve unchanged.
            reconnectSchedule.restartForPathChange()
            return
        }
        guard reconnectTask == nil else { return }
        // Nothing is waiting, so the restart only has to drop the curve the
        // closed route had grown before the attempt that follows.
        reconnectSchedule.reset()
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
        // These three refusals keep the state that explains them, and none of
        // them may publish a recovery state: `.offline` is the only status that
        // offers Retry, so a non-retryable stop turned into `.reconnecting`
        // would leave the phone with neither recovery nor a way to start one.
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
            // A lost socket on a known-down route is the parked episode: name it
            // and arm the bound that resumes it, instead of returning silently
            // the way the 2026-09-27 gap did (C-1). Parking owns the state.
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
        reconnectLoopID = nil
        reconnectAttemptInFlightLoop = nil
        foregroundReconciliationTask = nil
        deferredProjectionTask = nil
        cancelDeferredProjection()
        backgroundRetirementTask = nil
        foregroundReconciliationGeneration &+= 1
        cancelParkedRetry()
        // A profile switch, pairing or teardown stops the episode this lifecycle
        // was explaining; the new generation will open its own if it fails. The
        // episode keeps its own profile and generation: the transition that
        // ended it is not necessarily the one it was about.
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
        // Claim the whole operation before cache I/O yields. Startup, path,
        // foreground, and profile-switch work must not create a peer hello.
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
            // A live socket is not parked recovery: drop any bound the loss that
            // preceded this connect armed, and any loop that somehow survived it.
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

    /// Mounted restoration, refresh and terminal reattachment run beneath the
    /// connection they were admitted for, owned by the presentation that
    /// implements them. No connection task awaits them: slow projection work
    /// must not delay a replacement attempt, and the socket's loss cancels the
    /// projection instead of letting a late result publish over the replacement
    /// (C-1).
    private func beginDeferredProjection(admission: Admission) {
        cancelDeferredProjection()
        deferredProjectionAdmission = admission
        deferredProjectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            async let refresh: Void = self.delegate?.lifecycleRefreshAll(admission: admission) ?? ()
            async let restore = self.delegate?.lifecycleRestoreMountedPresentation(admission: admission) ?? true
            async let terminals: Void = self.delegate?.lifecycleReattachTerminals(admission: admission) ?? ()
            let (_, restored, _) = await (refresh, restore, terminals)
            guard !Task.isCancelled, self.admits(admission) else { return }
            // The event reducer can lag transport retirement: consult the client
            // before publishing a projection for a socket that is already gone.
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
            // Projection failure leaves the live socket usable; only transport
            // failure may recycle it.
            self.deferredProjectionTask = nil
        }
    }

    /// Cancelling a projection settles the admission it was reconciling: the
    /// cancelled task returns before publishing a result, and an aggregate left
    /// open keeps `isReconcilingForeground` true, which freezes the mounted chat
    /// and blocks uploads for the whole outage.
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
        reconnectLoopID = nil
        reconnectAttemptInFlightLoop = nil
        task?.cancel()
    }

    /// Recovery is parked: foreground, disconnected, and nothing in flight or
    /// scheduled because the last path hint said unsatisfied. The bound makes
    /// recovery scheduled instead of silent, so a missed callback cannot leave
    /// the phone quiet in the foreground (C-1), and the stall watchdog reads a
    /// parked episode as progressing rather than stalled. Parking owns the state
    /// it publishes: a park that is refused (a stop the user must clear, an
    /// attempt already owns the timeline, or a bound already armed) must not
    /// leave a recovery status behind that no user action can leave.
    private func parkRecovery(reason: String) {
        guard phase.admitsWork, !sceneIsBackgrounded, !nonRetryableRecoveryFailure,
              profiles.selected != nil, parkedRetryTask == nil else { return }
        // An in-flight initial connect, committed replacement attempt or pairing
        // owns the attempt: parking would publish `.reconnecting` over its
        // `.connecting` and arm a bound that outlives its result (`connect`
        // returns silently on a state mismatch, so a pairing would report
        // success with no socket). Its own retryable-failure branch schedules
        // recovery; whoever releases the attempt re-parks a stale unsatisfied
        // hint (`parkUnsatisfiedPathWhenIdle`).
        guard connectionAdmissionTask == nil, committedConnectionTask == nil,
              pairingAttempt == nil else { return }
        // `.offline`, `.unpaired` and `.unauthorized` are stops with their own
        // surface (the first is the only one that offers Retry); a lost socket
        // whose status still reads connected is stale bookkeeping and is parked.
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
            // The hint is stale: one attempt proves the path either way, and a
            // failing one parks recovery again.
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

    /// A connect that owns the attempt cannot park itself (`parkRecovery`
    /// refuses an in-flight admission), and its retryable-failure branch runs
    /// while it still owns it. Whoever releases the task parks a stale
    /// unsatisfied hint here, so a route the initial connect could not reach
    /// still has its bound instead of waiting for a callback that may never come
    /// (C-1). A released attempt that left another attempt running is that
    /// attempt's timeline, not this one's.
    private func parkUnsatisfiedPathWhenIdle() {
        guard connectionID == nil, !networkPathSatisfied, reconnectTask == nil else { return }
        parkRecovery(reason: "pathUnsatisfied")
    }

    /// Every early return of `requestReconnect`/`scheduleReconnect` names the
    /// guard that refused it, so a silent park is impossible to reintroduce.
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
        reconnectLoopID = nil
        reconnectAttemptInFlightLoop = nil
    }

    /// The furthest handshake stage an attempt reached. The client's own
    /// handshake diagnostic is authoritative when it has one; otherwise an
    /// epoch means the hello was accepted, and only this client's own transport
    /// codes mean the attempt never got past opening the socket.
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

    /// One `gateway.attempt` record, plus the episode bookkeeping it implies.
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
        // A probe loop starts one attempt despite a stale unsatisfied hint; from
        // its second iteration the hint gates it again, so a path that is still
        // down parks recovery rather than spinning (C-1).
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
            // Whatever ends this loop — success, a state mismatch that returns
            // early, a path park or cancellation — a later drop must not read a
            // dead loop's marker as an attempt in flight. The identity check
            // keeps a replaced loop from clearing its successor's marker.
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
                    // A path can become unsatisfied while the predecessor socket
                    // is still active. Once that attempt retires, park until the
                    // next path callback instead of retrying on a known-down route.
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
                    // The loop is inside one transport attempt until this
                    // attempt ends; the stall watchdog reads this identity to
                    // tell a running attempt from a parked loop.
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
                            message: "attempt=\(attemptGeneration) loop=\(loopID) retry=\(retry) connectionID=\(connection.id) gatewayConnectionId=\(connection.gatewayConnectionID ?? "unknown") handshakeMs=\(diagnosticMilliseconds(startedAt.duration(to: clock.now())))")
                        self.recordAttempt(
                            attemptID: loopID, retry: retry, startedAt: startedAt,
                            delayBeforeMs: diagnosticMilliseconds(delayStartedAt.duration(to: startedAt)),
                            stageReached: "connected", reason: nil, succeeded: true,
                            gatewayConnectionID: connection.gatewayConnectionID,
                            connectionID: connection.id
                        )
                        // The transport attempt ends here: an authenticated
                        // socket plus its event stream is the connection
                        // boundary. Projection work runs beneath it, owned by the
                        // presentation, so a slow mounted restoration can never
                        // park this loop, and a drop under projection starts the
                        // next attempt at once instead of waiting it out (C-1).
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
                        // The attempt is over; the loop now waits in its bounded
                        // backoff, which the stall watchdog reads as progressing.
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
                            // A probe attempt that failed on a known-down route
                            // parks like the loop's own path check: the hint may
                            // still be stale, and only the bound brings the next
                            // attempt without a callback (C-1). Ending the loop
                            // here without a park is the silent gap again.
                            self.parkRecovery(reason: "pathUnsatisfied")
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
