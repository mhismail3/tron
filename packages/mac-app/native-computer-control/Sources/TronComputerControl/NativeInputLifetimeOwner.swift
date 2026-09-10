import Foundation

/// Trusted host code retains one scope across its related operations. Reconstructing
/// an operation cannot renew a scope revoked by physical takeover.
internal final class NativeInputControlScope: @unchecked Sendable {
    let binding: NativeControlScopeBinding
    private let lock = NSLock()
    private var revoked = false
    init(binding: NativeControlScopeBinding) { self.binding = binding }
    var isRevoked: Bool { lock.withLock { revoked } }
    func revoke() { lock.withLock { revoked = true } }
}

/// One completion owns all native awaits and the real interlock. A deadline only
/// closes admission/publishes needsRecovery; it NEVER races the native call to return.
internal final class NativeInputLifetimeOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let operationID = UUID()
    private let target: NativeControlTargetBinding
    private let controlScope: NativeInputControlScope
    private var scope: NativeControlScopeBinding { controlScope.binding }
    private let backend: any NativeInputIO
    private let constructed: ConstructedInputPlan
    private let lease: NativeControlInterlockLease
    private let recoveryGate = NativeRecoveryGate()
    private let ioDeadlineMilliseconds: UInt32
    private var completionTask: Task<NativeOperationReport, Never>!

    private var status: NativeOperationStatus = .preparing
    private var stopRequested = false
    private var controlRevision: UInt64 = 0
    private var timeoutOccurred = false
    private var finished = false
    private var awaitingRecovery = false
    private var nativeCall: UUID?
    private var delayTask: Task<Void, Never>?
    private var attempted = Set<Int>()
    private var accepted = Set<Int>()
    private var observed = Set<Int>()
    private var uncertainEvents = Set<Int>()
    private var held: [HeldInputIdentity: Int] = [:]
    private var ambiguousOpenings = Set<Int>()
    private var nextSequence: UInt64 = 1
    private var lastBackendSequence: UInt64 = 0
    private var focusAttempted = 0
    private var focusAccepted = 0
    private var focusObserved = 0
    private var focusUncertain = false

    init(plan: InputPlan, limits: InputConstructionLimits = .init(), root: NativeControlInterlockRoot,
         target: NativeControlTargetBinding, scope: NativeInputControlScope,
         backend: any NativeInputIO, ioDeadlineMilliseconds: UInt32 = 5_000) throws {
        guard !scope.isRevoked, target.processGeneration > 0, target.windowGeneration > 0,
              target.sessionGeneration > 0, scope.binding.generation > 0,
              (1...30_000).contains(ioDeadlineMilliseconds) else {
            throw NativeOwnerFailure.rejected("invalid or revoked native control binding")
        }
        constructed = try InputConstructor.construct(plan, limits: limits)
        lease = try root.acquire()
        guard !scope.isRevoked else {
            try lease.retire()
            throw NativeOwnerFailure.rejected("native control scope was revoked during admission")
        }
        _ = try lease.arm()
        self.target = target
        controlScope = scope
        self.backend = backend
        self.ioDeadlineMilliseconds = ioDeadlineMilliseconds
        completionTask = nil
        completionTask = Task.detached { [self] in await execute() }
    }

    func wait() async -> NativeOperationReport {
        await withTaskCancellationHandler {
            await completionTask.value
        } onCancel: {
            self.requestStop()
        }
    }

    func requestStop() {
        let delay = lock.withLock {
            if !stopRequested { controlRevision += 1 }
            stopRequested = true
            if !finished, status != .needsRecovery { status = .stopping }
            return delayTask
        }
        // This cancels only our timer, never native dispatch/observation or completion.
        delay?.cancel()
    }

    func requestTakeover() {
        let delay = lock.withLock {
            if !controlScope.isRevoked { controlRevision += 1 }
            controlScope.revoke()
            if !stopRequested { controlRevision += 1 }
            stopRequested = true
            if !finished, status != .needsRecovery { status = .stopping }
            return delayTask
        }
        delay?.cancel()
    }

    func snapshot() -> NativeOperationSnapshot {
        lock.withLock { .init(status: status, accounting: accountingLocked()) }
    }

    /// This asks the trusted backend for evidence, not a caller-supplied Boolean.
    /// Recovery cannot overlap a native call, even after that call's deadline.
    func recover() async -> NativeRecoveryOutcome {
        let request: NativeQuiescenceRequest? = lock.withLock {
            guard awaitingRecovery, nativeCall == nil, !finished else { return nil }
            awaitingRecovery = false
            return quiescenceRequestLocked()
        }
        guard let request else { return .unavailable("owner is not awaiting recovery or native work is still active") }
        let result = await io { [backend] _ in await backend.recover(request) }
        guard case let .quiescent(evidence) = result else {
            lock.withLock { awaitingRecovery = true }
            return result
        }
        let valid = lock.withLock { evidenceMatchesLocked(evidence, request: request) }
        guard valid else {
            lock.withLock { awaitingRecovery = true }
            return .unavailable("recovery evidence is stale, foreign, or incomplete")
        }
        recoveryGate.offer(evidence)
        return result // Backend evidence is not the operation's final completion.
    }

    private func io<T: Sendable>(_ body: @escaping @Sendable (UUID) async -> T) async -> T {
        let identity = UUID()
        lock.withLock {
            precondition(nativeCall == nil, "native I/O must remain serialized")
            nativeCall = identity
        }
        let monitor = Task.detached { [weak self, ioDeadlineMilliseconds] in
            do { try await Task.sleep(for: .milliseconds(ioDeadlineMilliseconds)) } catch { return }
            guard let self else { return }
            self.lock.withLock {
                guard self.nativeCall == identity, !self.finished else { return }
                self.timeoutOccurred = true
                if !self.stopRequested { self.controlRevision += 1 }
                self.stopRequested = true
                self.status = .needsRecovery
            }
        }
        let result = await body(identity)
        // Linearize return against the deadline before cooperative cancellation:
        // a monitor that already woke must see this exact call as retired.
        lock.withLock { nativeCall = nil }
        monitor.cancel()
        return result
    }

    private func execute() async -> NativeOperationReport {
        var primary: String?
        if !isStopping() {
            // Preparation may activate/raise before returning. Reserve that possible
            // effect until the backend proves either exact focus or no mutation.
            lock.withLock { focusAttempted = 1; focusUncertain = true }
            let preparation = await io { [self] callID in
                await backend.prepare(operationID: operationID, target: target, scope: scope,
                                      admission: admission(for: callID, isRelease: false))
            }
            switch preparation {
            case let .ready(evidence):
                do { try acceptPreparation(evidence) } catch { primary = String(describing: error) }
            case let .notPrepared(reason):
                lock.withLock { focusAttempted = 0; focusUncertain = false }
                primary = "preparation refused: \(reason)"
            case let .uncertain(reason):
                lock.withLock { focusAttempted = 1; focusUncertain = true }
                primary = "preparation uncertain: \(reason)"
            }
        }
        if primary == nil, !isStopping() {
            lock.withLock { status = .running }
            for event in constructed.events {
                if isStopping(), event.kind != .matchedRelease { break }
                do { try await process(event) } catch { primary = String(describing: error); break }
            }
        }
        return await settle(primary: primary)
    }

    private func acceptPreparation(_ evidence: NativePreparationEvidence) throws {
        try lock.withLock {
            guard evidence.operationID == operationID, evidence.target == target, evidence.scope == scope,
                  evidence.backendSequence > lastBackendSequence else {
                focusAttempted = 1; focusUncertain = true
                throw NativeOwnerFailure.evidence("foreign or stale preparation evidence")
            }
            lastBackendSequence = evidence.backendSequence
            if let focus = evidence.focus {
                focusAttempted = 1
                guard focus.ticket == .init(operationID: operationID, target: target, scope: scope),
                      focus.target == target, focus.scope == scope,
                      focus.backendSequence > lastBackendSequence else {
                    focusUncertain = true
                    throw NativeOwnerFailure.evidence("foreign or stale focus evidence")
                }
                focusAccepted = 1; focusObserved = 1; focusUncertain = false
                lastBackendSequence = focus.backendSequence
            } else {
                focusAttempted = 0; focusUncertain = false
            }
        }
    }

    private func process(_ event: ConstructedInputEvent) async throws {
        if event.kind == .delay {
            await delay(milliseconds: event.delayMilliseconds ?? 0)
            return
        }
        let ticket: NativeInputEventTicket? = lock.withLock {
            if event.kind == .newInput, stopRequested || controlScope.isRevoked { return nil }
            guard !attempted.contains(event.ordinal) else { return nil }
            if let release = event.release {
                guard held[release.identity] == release.pairedInputOrdinal,
                      !ambiguousOpenings.contains(release.pairedInputOrdinal) else { return nil }
            }
            let ticket = NativeInputEventTicket(operationID: operationID, target: target, scope: scope,
                                                eventOrdinal: event.ordinal, sequence: nextSequence)
            nextSequence += 1
            attempted.insert(event.ordinal)
            uncertainEvents.insert(event.ordinal)
            // Reserve ownership BEFORE native dispatch can start or suspend.
            if let resource = event.resourceIdentity {
                held[resource] = event.ordinal
                ambiguousOpenings.insert(event.ordinal)
            }
            return ticket
        }
        guard let ticket else { return }
        let isRelease = event.kind == .matchedRelease
        let result = await io { [self, ordinal = event.ordinal] callID in
            let request = NativeDispatchRequest(ticket: ticket, event: constructed.events[ordinal],
                                                 admission: admission(for: callID, isRelease: isRelease))
            return await backend.dispatch(request)
        }
        switch result {
        case let .notDispatched(reason):
            lock.withLock {
                uncertainEvents.remove(event.ordinal)
                if let resource = event.resourceIdentity, held[resource] == event.ordinal {
                    held.removeValue(forKey: resource); ambiguousOpenings.remove(event.ordinal)
                }
            }
            throw NativeOwnerFailure.rejected("event \(event.ordinal): \(reason)")
        case let .uncertain(reason):
            throw NativeOwnerFailure.rejected("event \(event.ordinal) uncertain: \(reason)")
        case let .accepted(ack):
            try lock.withLock {
                guard ack.ticket == ticket, ack.target == target, ack.scope == scope,
                      !accepted.contains(event.ordinal), ack.backendSequence > lastBackendSequence else {
                    throw NativeOwnerFailure.evidence("foreign, stale, or duplicate dispatch acknowledgement")
                }
                accepted.insert(event.ordinal); lastBackendSequence = ack.backendSequence
            }
            let outcome = await io { [backend] _ in await backend.observe(ticket, after: ack) }
            guard case let .observed(observation) = outcome else {
                throw NativeOwnerFailure.evidence("native event observation unavailable")
            }
            try lock.withLock {
                let expected: NativeObservedTransition
                if let release = event.release { expected = .up(release.identity) }
                else if let resource = event.resourceIdentity { expected = .down(resource) }
                else { expected = .none }
                guard observation.ticket == ticket, observation.target == target, observation.scope == scope,
                      observation.backendSequence > lastBackendSequence, observation.transition == expected,
                      !observed.contains(event.ordinal) else {
                    throw NativeOwnerFailure.evidence("foreign, stale, duplicate, or mismatched event observation")
                }
                lastBackendSequence = observation.backendSequence
                observed.insert(event.ordinal); uncertainEvents.remove(event.ordinal)
                if event.resourceIdentity != nil { ambiguousOpenings.remove(event.ordinal) }
                if let release = event.release, held[release.identity] == release.pairedInputOrdinal {
                    held.removeValue(forKey: release.identity); ambiguousOpenings.remove(release.pairedInputOrdinal)
                }
            }
        }
    }

    private func delay(milliseconds: UInt32) async {
        guard milliseconds > 0 else { return }
        let timer: Task<Void, Never>? = lock.withLock {
            guard !stopRequested, !controlScope.isRevoked else { return nil }
            let timer = Task<Void, Never> {
                do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { }
            }
            delayTask = timer
            status = .waitingDelay
            return timer
        }
        guard let timer else { return }
        await timer.value
        lock.withLock {
            delayTask = nil
            status = stopRequested || controlScope.isRevoked ? .stopping : .running
        }
    }

    private func settle(primary original: String?) async -> NativeOperationReport {
        var primary = original
        lock.withLock { if primary != nil || stopRequested { status = .stopping } }
        for event in constructed.events where event.kind == .matchedRelease {
            do { try await process(event) } catch { primary = primary ?? String(describing: error) }
        }
        let request = lock.withLock { quiescenceRequestLocked() }
        let outcome = await io { [backend] _ in await backend.quiescence(request) }
        var released = false
        if case let .quiescent(evidence) = outcome {
            released = acceptQuiescence(evidence, request: request)
            if !released { primary = primary ?? "native input evidence rejected: stale or incomplete quiescence" }
        }
        while !released {
            lock.withLock { status = .needsRecovery; awaitingRecovery = true }
            // An explicit recovery wait is intentionally not a timer-to-success.
            // Actual work/resources and completion remain owned until valid evidence.
            let evidence = await recoveryGate.wait()
            let current = lock.withLock { quiescenceRequestLocked() }
            released = acceptQuiescence(evidence, request: current)
        }
        var retirementError: String?
        do { try lease.retireAfterTrustedNativeRelease() }
        catch { retirementError = String(describing: error) }
        // Native release is proven and the file operation has returned. Report a
        // retirement failure once; never loop trying to recover an already-removed
        // marker or retry a consumed descriptor. Remaining quarantine blocks admission.
        return lock.withLock {
            finished = true; awaitingRecovery = false; status = .settled
            let reason = [primary, retirementError.map { "interlock retirement failed: \($0)" },
                          timeoutOccurred ? "native I/O deadline exceeded; native work was joined" : nil]
                .compactMap { $0 }.joined(separator: "; ")
            let completion: NativeOperationCompletion = reason.isEmpty
                ? ((stopRequested || controlScope.isRevoked) ? .stopped : .completed) : .failed(reason)
            return .init(operationID: operationID, outcome: completion, accounting: accountingLocked())
        }
    }

    private func evidenceMatchesLocked(_ evidence: NativeQuiescenceEvidence,
                                       request: NativeQuiescenceRequest) -> Bool {
        request == quiescenceRequestLocked()
            && evidence.operationID == operationID && evidence.target == target && evidence.scope == scope
            && evidence.controlRevision == request.controlRevision
            && evidence.resolvedEventOrdinals == request.uncertainEventOrdinals
            && evidence.releasedResourceOpeningOrdinals == request.pendingResourceOpeningOrdinals
            && evidence.focusResolved && evidence.scopeRevoked == request.scopeRevoked
            && evidence.backendSequence > lastBackendSequence
    }

    private func acceptQuiescence(_ evidence: NativeQuiescenceEvidence,
                                  request: NativeQuiescenceRequest) -> Bool {
        lock.withLock {
            guard nativeCall == nil, evidenceMatchesLocked(evidence, request: request) else { return false }
            lastBackendSequence = evidence.backendSequence
            uncertainEvents.removeAll(); ambiguousOpenings.removeAll(); held.removeAll(); focusUncertain = false
            awaitingRecovery = false
            return true
        }
    }

    private func quiescenceRequestLocked() -> NativeQuiescenceRequest {
        .init(operationID: operationID, target: target, scope: scope,
              uncertainEventOrdinals: uncertainEvents.sorted(), pendingResourceOpeningOrdinals: heldOrdinalsLocked(),
              focusUncertain: focusUncertain, scopeRevoked: controlScope.isRevoked, controlRevision: controlRevision)
    }
    private func heldOrdinalsLocked() -> [Int] { Set(held.values).union(ambiguousOpenings).sorted() }
    private func isStopping() -> Bool { lock.withLock { stopRequested || controlScope.isRevoked } }
    private func admission(for callID: UUID, isRelease: Bool) -> NativeInputAdmission {
        NativeInputAdmission { [weak self] in
            guard let self else { return false }
            return self.lock.withLock {
                self.nativeCall == callID && !self.finished
                    && (isRelease || (!self.stopRequested && !self.controlScope.isRevoked))
            }
        }
    }
    private func accountingLocked() -> NativeOperationAccounting {
        .init(attemptedEventOrdinals: attempted.sorted(), acceptedEventOrdinals: accepted.sorted(),
              observedEventOrdinals: observed.sorted(), focusEffectsAttempted: focusAttempted,
              focusEffectsAccepted: focusAccepted, focusEffectsObserved: focusObserved,
              heldOpeningOrdinals: heldOrdinalsLocked())
    }
}
