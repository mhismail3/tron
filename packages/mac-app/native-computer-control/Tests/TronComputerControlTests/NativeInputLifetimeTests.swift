import Foundation
import Darwin
import XCTest
@testable import TronComputerControl

final class NativeInputLifetimeTests: XCTestCase {
    func testExactOperationCompletesAndAllWaitersShareOneDispatch() async throws {
        try await withFixture { f in
            let report = try await f.report()
            let second = await f.owner.wait()
            XCTAssertEqual(report, second)
            XCTAssertEqual(report.outcome, .completed)
            XCTAssertEqual(report.accounting.attemptedEventOrdinals, [0, 1])
            XCTAssertEqual(report.accounting.acceptedEventOrdinals, [0, 1])
            XCTAssertEqual(report.accounting.observedEventOrdinals, [0, 1])
            XCTAssertTrue(report.accounting.heldOpeningOrdinals.isEmpty)
            let ordinals = await f.io.ordinals()
            XCTAssertEqual(ordinals, [0, 1])
            XCTAssertFalse(f.markerExists)
        }
    }

    func testAdmissionsExpireAtTheirOwnNativeReturnWhileOperationRemainsActive() async throws {
        try await withFixture(configuration: .init(block: .observation)) { f in
            try await f.waitFor(.observation)
            XCTAssertNotEqual(f.owner.snapshot().status, .settled)
            let retained = await f.io.admissionsStillAllowed()
            XCTAssertEqual(retained, [false, false], "old prepare/post admissions must expire during observe")
            f.gate.open()
            _ = try await f.report()
            let finished = await f.io.admissionsStillAllowed()
            XCTAssertTrue(finished.allSatisfy { !$0 })
        }
    }

    func testDefiniteNoDispatchDoesNotInventARelease() async throws {
        try await withFixture(configuration: .init(dispatchFailure: .definite)) { f in
            let report = try await f.report()
            guard case .failed = report.outcome else { return XCTFail("Expected failure") }
            XCTAssertEqual(report.accounting.attemptedEventOrdinals, [0])
            XCTAssertTrue(report.accounting.acceptedEventOrdinals.isEmpty)
            XCTAssertTrue(report.accounting.heldOpeningOrdinals.isEmpty)
            let ordinals = await f.io.ordinals()
            XCTAssertEqual(ordinals, [0])
        }
    }

    func testUncertainDownKeepsCompletionAndIndependentContenderBlocked() async throws {
        try await withFixture(configuration: .init(dispatchFailure: .uncertain, quiescenceUnavailable: true,
                                                   recoveryUncertain: [0], recoveryHeld: [0])) { f in
            try await f.waitForRecovery()
            XCTAssertEqual(f.owner.snapshot().accounting.heldOpeningOrdinals, [0])
            XCTAssertTrue(f.markerExists)
            XCTAssertEqual(try f.contender(), 75)
            let result = await f.owner.recover()
            guard case .quiescent = result else { return XCTFail("Expected recovery evidence") }
            let report = try await f.report()
            XCTAssertEqual(report.accounting.attemptedEventOrdinals, [0])
            XCTAssertTrue(report.accounting.acceptedEventOrdinals.isEmpty)
            XCTAssertTrue(report.accounting.heldOpeningOrdinals.isEmpty)
            XCTAssertFalse(f.markerExists)
            XCTAssertEqual(try f.contender(), 0)
        }
    }

    func testUncertainUpIsNotReplayedDuringCleanupOrRecovery() async throws {
        try await withFixture(configuration: .init(dispatchFailure: .uncertainUp, quiescenceUnavailable: true,
                                                   recoveryUncertain: [1], recoveryHeld: [0])) { f in
            try await f.waitForRecovery()
            _ = await f.owner.recover()
            let report = try await f.report()
            XCTAssertEqual(report.accounting.attemptedEventOrdinals, [0, 1])
            XCTAssertEqual(report.accounting.acceptedEventOrdinals, [0])
            XCTAssertEqual(report.accounting.observedEventOrdinals, [0])
            let ordinals = await f.io.ordinals()
            XCTAssertEqual(ordinals, [0, 1])
        }
    }

    func testStopDuringBackendEventPreparationRefusesTheActualNativePost() async throws {
        try await withFixture(configuration: .init(block: .dispatchPreparation)) { f in
            try await f.waitFor(.dispatchPreparation)
            f.owner.requestStop()
            f.gate.open()
            let report = try await f.report()
            XCTAssertEqual(report.accounting.attemptedEventOrdinals, [0])
            XCTAssertTrue(report.accounting.acceptedEventOrdinals.isEmpty)
            XCTAssertTrue(report.accounting.heldOpeningOrdinals.isEmpty)
            let posted = await f.io.reached(.dispatch)
            XCTAssertFalse(posted)
        }
    }

    func testStopDuringBackendFocusPreparationRefusesFocusMutation() async throws {
        try await withFixture(configuration: .init(block: .preparationBeforeDispatch, includeFocus: true)) { f in
            try await f.waitFor(.preparationBeforeDispatch)
            f.owner.requestStop()
            f.gate.open()
            let report = try await f.report()
            XCTAssertEqual(report.accounting.focusEffectsAttempted, 0)
            XCTAssertTrue(report.accounting.attemptedEventOrdinals.isEmpty)
            let focused = await f.io.reached(.preparation)
            XCTAssertFalse(focused)
        }
    }

    func testStopDuringPostReservesHeldResourceBeforeBackendReturns() async throws {
        try await withFixture(configuration: .init(block: .dispatch)) { f in
            try await f.waitFor(.dispatch)
            XCTAssertEqual(f.owner.snapshot().accounting.heldOpeningOrdinals, [0])
            f.owner.requestStop()
            XCTAssertEqual(try f.contender(), 75)
            f.gate.open()
            let report = try await f.report()
            XCTAssertEqual(report.outcome, .stopped)
            XCTAssertEqual(report.accounting.attemptedEventOrdinals, [0, 1])
            XCTAssertTrue(report.accounting.heldOpeningOrdinals.isEmpty)
        }
    }

    func testCancelledWaiterJoinsNativeObservationAndCleanup() async throws {
        try await withFixture(configuration: .init(block: .observation)) { f in
            try await f.waitFor(.observation)
            let waiter = Task { await f.owner.wait() }
            waiter.cancel()
            try await eventually { f.owner.snapshot().status == .stopping }
            XCTAssertEqual(try f.contender(), 75)
            f.gate.open()
            let report = try await f.report()
            let joined = await waiter.value
            XCTAssertEqual(joined, report)
            XCTAssertEqual(report.outcome, .stopped)
            XCTAssertEqual(report.accounting.observedEventOrdinals, [0, 1])
        }
    }

    func testDeadlinePublishesRecoveryWithoutAbandoningBlockedNativeCall() async throws {
        try await withFixture(configuration: .init(block: .dispatch), deadline: 25) { f in
            try await f.waitFor(.dispatch)
            try await f.waitForRecovery()
            XCTAssertEqual(try f.contender(), 75)
            let premature = await f.owner.recover()
            guard case .unavailable = premature else { return XCTFail("Recovery cannot overlap native dispatch") }
            XCTAssertEqual(f.owner.snapshot().accounting.heldOpeningOrdinals, [0])
            f.gate.open()
            let report = try await f.report()
            guard case let .failed(message) = report.outcome else { return XCTFail("Timeout is not normal success") }
            XCTAssertTrue(message.contains("deadline"))
            XCTAssertEqual(report.accounting.attemptedEventOrdinals, [0, 1])
            XCTAssertFalse(f.markerExists)
        }
    }

    func testStopDuringDelayAdmitsNoFollowingInput() async throws {
        try await withFixture(plan: .init(actions: [.delay(milliseconds: 30_000), .key(.init(.a))])) { f in
            try await eventually { f.owner.snapshot().status == .waitingDelay }
            f.owner.requestStop()
            let report = try await f.report()
            XCTAssertEqual(report.outcome, .stopped)
            XCTAssertTrue(report.accounting.attemptedEventOrdinals.isEmpty)
        }
    }

    func testStopDuringHeldDelayCancelsTimerButStillJoinsMatchingMouseUp() async throws {
        let bounds = LogicalScreenBounds(origin: .init(x: 0, y: 0), width: 100, height: 100)
        let plan = InputPlan(actions: [.mouse(.click(.init(point: .init(x: 10, y: 10), holdMilliseconds: 2_000)))], targetBounds: bounds)
        let expected: [Int: NativeObservedTransition] = [0: .down(.mouseButton(.left)), 2: .up(.mouseButton(.left))]
        try await withFixture(configuration: .init(transitions: expected), plan: plan) { f in
            try await eventually { f.owner.snapshot().status == .waitingDelay }
            XCTAssertEqual(f.owner.snapshot().accounting.heldOpeningOrdinals, [0])
            f.owner.requestStop()
            let report = try await f.report()
            XCTAssertEqual(report.outcome, .stopped)
            XCTAssertEqual(report.accounting.attemptedEventOrdinals, [0, 2])
            XCTAssertTrue(report.accounting.heldOpeningOrdinals.isEmpty)
        }
    }

    func testWrongTargetScopeTicketResourceAndSameSequenceEvidenceStaysPending() async throws {
        for invalid in [InvalidEvidence.target, .scope, .ticket, .resource, .sameSequence] {
            try await withFixture(configuration: .init(invalidObservation: invalid, quiescenceUnavailable: true,
                                                       recoveryUncertain: [0], recoveryHeld: [0])) { f in
                try await f.waitForRecovery()
                XCTAssertEqual(try f.contender(), 75)
                XCTAssertEqual(f.owner.snapshot().accounting.acceptedEventOrdinals, [0])
                XCTAssertTrue(f.owner.snapshot().accounting.observedEventOrdinals.isEmpty)
                _ = await f.owner.recover()
                let report = try await f.report()
                guard case .failed = report.outcome else { return XCTFail("Invalid observation cannot succeed") }
                let ordinals = await f.io.ordinals()
                XCTAssertEqual(ordinals, [0])
            }
        }
    }

    func testReplayedAcknowledgementCannotAccountForADifferentNativeEvent() async throws {
        try await withFixture(configuration: .init(quiescenceUnavailable: true, recoveryUncertain: [1],
                                                   recoveryHeld: [0], replayAcknowledgementOnUp: true)) { f in
            try await f.waitForRecovery()
            XCTAssertEqual(f.owner.snapshot().accounting.acceptedEventOrdinals, [0])
            XCTAssertEqual(try f.contender(), 75)
            _ = await f.owner.recover()
            let report = try await f.report()
            XCTAssertEqual(report.accounting.attemptedEventOrdinals, [0, 1])
            XCTAssertEqual(report.accounting.acceptedEventOrdinals, [0])
            let ordinals = await f.io.ordinals()
            XCTAssertEqual(ordinals, [0, 1])
        }
    }

    func testTakeoverWithHeldInputKeepsScopeRevokedThroughAuthoritativeRelease() async throws {
        try await withFixture(configuration: .init(dispatchFailure: .definiteUp, block: .observation,
                                                   quiescenceUnavailable: true, recoveryHeld: [0])) { f in
            try await f.waitFor(.observation)
            f.owner.requestTakeover()
            f.gate.open()
            try await f.waitForRecovery()
            XCTAssertEqual(f.owner.snapshot().accounting.heldOpeningOrdinals, [0])
            XCTAssertTrue(f.scope.isRevoked)
            XCTAssertEqual(try f.contender(), 75)
            _ = await f.owner.recover()
            let report = try await f.report()
            XCTAssertTrue(report.accounting.heldOpeningOrdinals.isEmpty)
            XCTAssertTrue(f.scope.isRevoked)
            XCTAssertFalse(f.markerExists)
        }
    }

    func testBadQuiescenceAndSameSequenceRecoveryCannotClearMarker() async throws {
        try await withFixture(configuration: .init(invalidQuiescence: true)) { f in
            try await f.waitForRecovery()
            XCTAssertTrue(f.markerExists)
            await f.io.setInvalidRecovery(true)
            let invalid = await f.owner.recover()
            guard case .unavailable = invalid else { return XCTFail("Same-sequence recovery accepted") }
            XCTAssertEqual(try f.contender(), 75)
            await f.io.setInvalidRecovery(false)
            _ = await f.owner.recover()
            _ = try await f.report()
            XCTAssertFalse(f.markerExists)
        }
    }

    func testTakeoverDuringQuiescenceRejectsOldProofAndRevokesFutureOperation() async throws {
        try await withFixture(configuration: .init(block: .quiescence)) { f in
            try await f.waitFor(.quiescence)
            f.owner.requestTakeover()
            f.gate.open()
            try await f.waitForRecovery()
            XCTAssertTrue(f.markerExists)
            _ = await f.owner.recover()
            _ = try await f.report()
            XCTAssertTrue(f.scope.isRevoked)
            XCTAssertThrowsError(try NativeInputLifetimeOwner(plan: .init(actions: [.key(.init(.a))]),
                root: NativeControlInterlockRoot(rootURL: f.root), target: f.target, scope: f.scope, backend: f.io))
            XCTAssertFalse(f.markerExists)
        }
    }

    func testTakeoverDuringFocusRetainsFocusEvidenceAndZeroInputPrefix() async throws {
        try await withFixture(configuration: .init(block: .preparation, includeFocus: true)) { f in
            try await f.waitFor(.preparation)
            f.owner.requestTakeover()
            f.gate.open()
            let report = try await f.report()
            XCTAssertEqual(report.outcome, .stopped)
            XCTAssertEqual(report.accounting.focusEffectsObserved, 1)
            XCTAssertTrue(report.accounting.attemptedEventOrdinals.isEmpty)
            XCTAssertTrue(f.scope.isRevoked)
        }
    }

    func testUnresolvedFocusRequiresPositiveResolutionNotEchoedFalse() async throws {
        try await withFixture(configuration: .init(invalidQuiescence: true, uncertainFocus: true)) { f in
            try await f.waitForRecovery()
            XCTAssertEqual(f.owner.snapshot().accounting.focusEffectsAttempted, 1)
            XCTAssertTrue(f.markerExists)
            _ = await f.owner.recover()
            let report = try await f.report()
            guard case .failed = report.outcome else { return XCTFail("Expected uncertain focus result") }
        }
    }

    func testRetirementErrorAfterMarkerRemovalTerminatesWithoutRecoveryLoop() async throws {
        try await withFixture(lateCloseError: true) { f in
            let report = try await f.report()
            guard case let .failed(message) = report.outcome else { return XCTFail("Expected retirement error") }
            XCTAssertTrue(message.contains("interlock retirement failed"))
            XCTAssertFalse(f.markerExists)
            let recoveries = await f.io.recoveries()
            XCTAssertEqual(recoveries, 0)
            let joined = await f.owner.wait()
            XCTAssertEqual(joined, report)
        }
    }

    private func withFixture(configuration: IOConfiguration = .init(),
                             plan: InputPlan = .init(actions: [.key(.init(.a))]), deadline: UInt32 = 5_000,
                             lateCloseError: Bool = false,
                             body: (LifetimeFixture) async throws -> Void) async throws {
        let fixture = try LifetimeFixture(configuration: configuration, plan: plan,
                                          deadline: deadline, lateCloseError: lateCloseError)
        do { try await body(fixture) }
        catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
}

private enum Phase: Hashable, Sendable { case preparationBeforeDispatch, preparation, dispatchPreparation, dispatch, observation, quiescence }
private enum DispatchFailure: Sendable { case none, definite, uncertain, uncertainUp, definiteUp }
private enum InvalidEvidence: Sendable { case none, target, scope, ticket, resource, sameSequence }
private struct IOConfiguration: Sendable {
    var dispatchFailure: DispatchFailure = .none
    var block: Phase? = nil
    var invalidObservation: InvalidEvidence = .none
    var quiescenceUnavailable = false
    var invalidQuiescence = false
    var includeFocus = false
    var uncertainFocus = false
    var recoveryUncertain: [Int] = []
    var recoveryHeld: [Int] = []
    var transitions: [Int: NativeObservedTransition] = [0: .down(.keyboard(0)), 1: .up(.keyboard(0))]
    var replayAcknowledgementOnUp = false
}

private final class LifetimeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if opened { return true }
                waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
    func open() {
        let continuations = lock.withLock {
            opened = true
            let result = waiters; waiters.removeAll(); return result
        }
        continuations.forEach { $0.resume() }
    }
}

private actor ControlledNativeIO: NativeInputIO {
    let configuration: IOConfiguration
    let gate: LifetimeGate
    private var sequence: UInt64 = 0
    private var seen: Set<Phase> = []
    private var submitted: [NativeDispatchRequest] = []
    private var recoveryCount = 0
    private var invalidRecovery = false
    private var lastObservedSequence: UInt64 = 0
    private var firstAcknowledgement: NativeDispatchAcknowledgement?
    private var retainedAdmissions: [NativeInputAdmission] = []
    init(_ configuration: IOConfiguration, gate: LifetimeGate) { self.configuration = configuration; self.gate = gate }
    func reached(_ phase: Phase) -> Bool { seen.contains(phase) }
    func ordinals() -> [Int] { submitted.map { $0.ticket.eventOrdinal } }
    func recoveries() -> Int { recoveryCount }
    func admissionsStillAllowed() -> [Bool] { retainedAdmissions.map(\.allowsDispatch) }
    func setInvalidRecovery(_ value: Bool) { invalidRecovery = value }
    private func next() -> UInt64 { sequence += 1; return sequence }
    private func enter(_ phase: Phase) async {
        seen.insert(phase)
        if configuration.block == phase { await gate.wait() }
    }
    func prepare(operationID: UUID, target: NativeControlTargetBinding, scope: NativeControlScopeBinding,
                 admission: NativeInputAdmission) async -> NativePreparationOutcome {
        retainedAdmissions.append(admission)
        if configuration.block == .preparationBeforeDispatch { await enter(.preparationBeforeDispatch) }
        guard admission.allowsDispatch else { return .notPrepared("owner stopped before focus dispatch") }
        await enter(.preparation)
        if configuration.uncertainFocus { return .uncertain("focus receipt lost") }
        let prepared = next()
        let focus: NativeFocusEffectObservation? = configuration.includeFocus
            ? .init(ticket: .init(operationID: operationID, target: target, scope: scope), target: target,
                    scope: scope, backendSequence: next()) : nil
        return .ready(.init(operationID: operationID, target: target, scope: scope,
                            backendSequence: prepared, focus: focus))
    }
    func dispatch(_ request: NativeDispatchRequest) async -> NativeDispatchOutcome {
        retainedAdmissions.append(request.admission)
        submitted.append(request)
        if configuration.block == .dispatchPreparation { await enter(.dispatchPreparation) }
        guard request.admission.allowsDispatch else { return .notDispatched("owner stopped before native post") }
        await enter(.dispatch)
        switch configuration.dispatchFailure {
        case .definite: return .notDispatched("permission denied")
        case .uncertain: return .uncertain("post response lost")
        case .uncertainUp where request.ticket.eventOrdinal == 1: return .uncertain("up response lost")
        case .definiteUp where request.ticket.eventOrdinal == 1: return .notDispatched("cleanup permission denied")
        default: break
        }
        if configuration.replayAcknowledgementOnUp, request.ticket.eventOrdinal == 1,
           let firstAcknowledgement { return .accepted(firstAcknowledgement) }
        let acknowledgement = NativeDispatchAcknowledgement(ticket: request.ticket, target: request.ticket.target,
                                                            scope: request.ticket.scope, backendSequence: next())
        if firstAcknowledgement == nil { firstAcknowledgement = acknowledgement }
        return .accepted(acknowledgement)
    }
    func observe(_ ticket: NativeInputEventTicket, after acknowledgement: NativeDispatchAcknowledgement) async -> NativeObservationOutcome {
        await enter(.observation)
        var target = ticket.target
        var scope = ticket.scope
        var observedTicket = ticket
        var seq = next()
        // Immutable literal native-state script, independent from event.resourceIdentity
        // and the owner's prediction: this fixture executes exactly ANSI A down/up.
        var transition: NativeObservedTransition = configuration.transitions[ticket.eventOrdinal] ?? .none
        switch configuration.invalidObservation {
        case .target: target = .init(processGeneration: 999, windowGeneration: 8, sessionGeneration: 12)
        case .scope: scope = .init(sourceID: UUID(), generation: 999)
        case .ticket:
            observedTicket = .init(operationID: ticket.operationID, target: ticket.target, scope: ticket.scope,
                                   eventOrdinal: ticket.eventOrdinal, sequence: ticket.sequence + 1)
        case .resource: transition = .down(.keyboard(11))
        case .sameSequence: seq = acknowledgement.backendSequence
        case .none: break
        }
        lastObservedSequence = seq
        return .observed(.init(ticket: observedTicket, target: target, scope: scope,
                               backendSequence: seq, transition: transition))
    }
    func quiescence(_ request: NativeQuiescenceRequest) async -> NativeQuiescenceOutcome {
        await enter(.quiescence)
        if configuration.quiescenceUnavailable { return .unavailable("requires independent recovery") }
        // Normal script proves no outstanding input; it does NOT echo requested lists.
        return .quiescent(.init(operationID: request.operationID, target: request.target, scope: request.scope,
            backendSequence: next(), resolvedEventOrdinals: [], releasedResourceOpeningOrdinals: [],
            focusResolved: !configuration.invalidQuiescence, scopeRevoked: request.scopeRevoked,
            controlRevision: request.controlRevision))
    }
    func recover(_ request: NativeRecoveryRequest) async -> NativeRecoveryOutcome {
        recoveryCount += 1
        return .quiescent(.init(operationID: request.operationID, target: request.target, scope: request.scope,
            backendSequence: invalidRecovery ? lastObservedSequence : next(),
            resolvedEventOrdinals: configuration.recoveryUncertain,
            releasedResourceOpeningOrdinals: configuration.recoveryHeld,
            focusResolved: true, scopeRevoked: request.scopeRevoked, controlRevision: request.controlRevision))
    }
}

private final class LifetimeFixture: @unchecked Sendable {
    let root: URL
    let target = NativeControlTargetBinding(processGeneration: 4, windowGeneration: 8, sessionGeneration: 12)
    let scope = NativeInputControlScope(binding: .init(sourceID: UUID(), generation: 3))
    let gate = LifetimeGate()
    let io: ControlledNativeIO
    let owner: NativeInputLifetimeOwner
    init(configuration: IOConfiguration, plan: InputPlan, deadline: UInt32, lateCloseError: Bool) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tron-native-lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        io = ControlledNativeIO(configuration, gate: gate)
        let interlock = try NativeControlInterlockRoot(rootURL: root, descriptorClose: { descriptor, kind in
            let result = Darwin.close(descriptor)
            if result == 0, lateCloseError, kind == .lock { errno = EIO; return -1 }
            return result
        })
        owner = try NativeInputLifetimeOwner(plan: plan, root: interlock, target: target, scope: scope,
                                             backend: io, ioDeadlineMilliseconds: deadline)
    }
    var markerExists: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("native-control.quarantine").path) }
    func waitFor(_ phase: Phase) async throws { try await eventually { await self.io.reached(phase) } }
    func waitForRecovery() async throws { try await eventually { self.owner.snapshot().status == .needsRecovery } }
    func report() async throws -> NativeOperationReport {
        try await eventually { self.owner.snapshot().status == .settled }
        return await owner.wait()
    }
    func finish() async {
        gate.open()
        owner.requestStop()
        await io.setInvalidRecovery(false)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while owner.snapshot().status != .settled, ProcessInfo.processInfo.systemUptime < deadline {
            if owner.snapshot().status == .needsRecovery { _ = await owner.recover() }
            try? await Task.sleep(for: .milliseconds(2))
        }
        guard owner.snapshot().status == .settled else {
            XCTFail("test owner did not retire; preserved root: \(root.path)")
            return // Never delete a coordination root still owned by pending work.
        }
        _ = await owner.wait()
        try? FileManager.default.removeItem(at: root)
    }
    func contender() throws -> Int32 {
        let process = Process()
        let ended = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import os, fcntl, sys
        fd = os.open(sys.argv[1], os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit(75)
        finally:
            os.close(fd)
        """, root.appendingPathComponent("native-control.lock").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        guard ended.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            if ended.wait(timeout: .now() + 1) != .success, process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = ended.wait(timeout: .now() + 2)
            }
            throw LifetimeTestTimeout()
        }
        return process.terminationStatus
    }
}

private struct LifetimeTestTimeout: Error {}
private func eventually(_ condition: () async -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while ProcessInfo.processInfo.systemUptime < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw LifetimeTestTimeout()
}
