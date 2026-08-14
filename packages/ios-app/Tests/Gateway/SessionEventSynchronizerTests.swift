import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Session synchronization coordination")
struct SessionEventSynchronizerTests {
    @Test("events are quarantined and drained after the authoritative baseline")
    func quarantinesAndReplays() {
        let coordinator = SessionSynchronizationCoordinator()
        let lease = coordinator.acquire(
            sessionID: "session",
            intent: .reconnect(presentationGeneration: 3)
        )
        #expect(lease.role == .leader)
        #expect(coordinator.admit(event(sequence: 10)) == .buffered)
        #expect(coordinator.admit(event(sequence: 11)) == .buffered)
        let replay = coordinator.drainBufferedEvents(
            for: lease,
            baseline: .init(runtimeGeneration: "generation", eventSequence: 10)
        )
        #expect(replay == [event(sequence: 11)])
        #expect(coordinator.drainBufferedEvents(for: lease, baseline: nil) == [])
    }

    @Test("compatible callers share one typed outcome without polling")
    func compatibleCallersShareOutcome() async {
        let coordinator = SessionSynchronizationCoordinator()
        let leader = coordinator.acquire(
            sessionID: "session",
            intent: .reconnect(presentationGeneration: 3)
        )
        let joined = coordinator.acquire(
            sessionID: "session",
            intent: .reconnect(presentationGeneration: 3)
        )
        #expect(leader.role == .leader)
        #expect(joined.role == .join)
        #expect(coordinator.intent(sessionID: "session") == .reconnect(presentationGeneration: 3))

        let waiter = Task { await joined.sharedValue() }
        coordinator.complete(leader, outcome: true)
        #expect(await waiter.value)
        #expect(coordinator.intent(sessionID: "session") == nil)
    }

    @Test("fresh presentation never inherits reconnect installation semantics")
    func incompatibleIntentRetriesAfterCurrent() {
        let coordinator = SessionSynchronizationCoordinator()
        _ = coordinator.acquire(
            sessionID: "session",
            intent: .reconnect(presentationGeneration: 3)
        )
        let fresh = coordinator.acquire(
            sessionID: "session",
            intent: .presentation(generation: 4)
        )
        #expect(fresh.role == .retryAfterCurrent)
    }

    @Test("cancelling a waiter does not cancel shared synchronization")
    func waiterCancellationIsLocal() async {
        let coordinator = SessionSynchronizationCoordinator()
        let leader = coordinator.acquire(
            sessionID: "session",
            intent: .reconnect(presentationGeneration: 3)
        )
        let joined = coordinator.acquire(
            sessionID: "session",
            intent: .reconnect(presentationGeneration: 3)
        )
        let cancelledWaiter = Task { await joined.sharedValue() }
        cancelledWaiter.cancel()
        #expect(await cancelledWaiter.value == false)
        let retainedWaiter = coordinator.acquire(
            sessionID: "session",
            intent: .reconnect(presentationGeneration: 3)
        )
        coordinator.complete(leader, outcome: true)
        #expect(await retainedWaiter.sharedValue())
    }

    @Test("a replacement runtime is replayed even when its sequence restarts")
    func replacementGeneration() {
        let coordinator = SessionSynchronizationCoordinator()
        let lease = coordinator.acquire(
            sessionID: "session",
            intent: .reconnect(presentationGeneration: 3)
        )
        #expect(coordinator.admit(event(sequence: 1, generation: "replacement")) == .buffered)
        let replay = coordinator.drainBufferedEvents(
            for: lease,
            baseline: .init(runtimeGeneration: "generation", eventSequence: 100)
        )
        #expect(replay == [event(sequence: 1, generation: "replacement")])
    }

    @Test("replay gaps and runtime replacements are rejected before publication")
    func replayContiguity() {
        let baseline = SessionSynchronizationCoordinator.Cursor(
            runtimeGeneration: "generation",
            eventSequence: 10
        )
        #expect(SessionSynchronizationCoordinator.isContiguous([
            event(sequence: 11), event(sequence: 12),
        ], after: baseline))
        #expect(!SessionSynchronizationCoordinator.isContiguous([
            event(sequence: 12),
        ], after: baseline))
        #expect(!SessionSynchronizationCoordinator.isContiguous([
            event(sequence: 11, generation: "replacement"),
        ], after: baseline))
    }

    @Test("retry and fresh-install requirements stay inside the synchronization owner")
    func invalidationOwnership() {
        let coordinator = SessionSynchronizationCoordinator()
        let lease = coordinator.acquire(
            sessionID: "session",
            intent: .reconnect(presentationGeneration: 3)
        )
        #expect(coordinator.markRetryRequired(sessionID: "session"))
        #expect(coordinator.consumeRetryRequirement(for: lease))
        #expect(!coordinator.consumeRetryRequirement(for: lease))
        coordinator.requireFreshInstall(sessionID: "session")
        #expect(coordinator.consumeFreshInstallRequirement(sessionID: "session"))
        #expect(!coordinator.consumeFreshInstallRequirement(sessionID: "session"))
    }

    @Test("fresh presentation consumes prior branch replacement without erasing a new one")
    func freshPresentationBranchRequirementLifecycle() {
        let coordinator = SessionSynchronizationCoordinator()
        coordinator.requireFreshInstall(sessionID: "session")
        let fresh = coordinator.acquire(
            sessionID: "session",
            intent: .presentation(generation: 4)
        )
        #expect(fresh.role == .leader)
        coordinator.prepareLeaderAttempt(fresh)
        #expect(!coordinator.consumeFreshInstallRequirement(sessionID: "session"))
        coordinator.requireFreshInstall(sessionID: "session")
        #expect(coordinator.consumeFreshInstallRequirement(sessionID: "session"))
    }

    @Test("buffer overflow requires another authoritative attempt")
    func overflow() {
        let coordinator = SessionSynchronizationCoordinator(maximumBufferedEvents: 2)
        let lease = coordinator.acquire(
            sessionID: "session",
            intent: .reconnect(presentationGeneration: 3)
        )
        #expect(coordinator.admit(event(sequence: 1)) == .buffered)
        #expect(coordinator.admit(event(sequence: 2)) == .buffered)
        #expect(coordinator.admit(event(sequence: 3)) == .overflow("session"))
        #expect(coordinator.drainBufferedEvents(
            for: lease,
            baseline: .init(runtimeGeneration: "generation", eventSequence: 0)
        ) == nil)
        coordinator.restartBuffer(for: lease)
        #expect(coordinator.drainBufferedEvents(for: lease, baseline: nil) == [])
    }

    @Test("reset resolves all shared work as unsuccessful")
    func resetResolvesWaiters() async {
        let coordinator = SessionSynchronizationCoordinator()
        let lease = coordinator.acquire(
            sessionID: "session",
            intent: .reconnect(presentationGeneration: 3)
        )
        let waiter = Task { await lease.sharedValue() }
        coordinator.reset()
        #expect(await waiter.value == false)
    }

    @Test("unknown sequenced topics remain consumable while malformed suffixes retry before publication")
    func replayPreparationAdmission() throws {
        let unknown = GatewayEvent(
            type: "event",
            topic: "session.future",
            sessionId: "session",
            payload: .object([
                "runtimeGeneration": .string("generation"),
                "eventSequence": .number(11),
                "revision": .number(11),
                "data": .object(["future": .bool(true)]),
            ])
        )
        guard case .sessionEvent(let prepared) = unknown.preparation else {
            Issue.record("unknown sequenced event did not preserve its envelope")
            return
        }
        #expect(prepared.data == .raw)
        #expect(SessionSynchronizationCoordinator.isContiguous(
            [unknown],
            after: .init(runtimeGeneration: "generation", eventSequence: 10)
        ))

        let malformedEnvelope = GatewayEvent(
            type: "event",
            topic: "session.future",
            sessionId: "session",
            payload: .object([
                "runtimeGeneration": .string("generation"),
                "eventSequence": .number(11),
            ])
        )
        #expect(malformedEnvelope.preparation == .none)
        #expect(!SessionSynchronizationCoordinator.isContiguous(
            [malformedEnvelope],
            after: .init(runtimeGeneration: "generation", eventSequence: 10)
        ))

        let malformedKnown = GatewayEvent(
            type: "event",
            topic: "session.toolProgress",
            sessionId: "session",
            payload: .object([
                "runtimeGeneration": .string("generation"),
                "eventSequence": .number(11),
                "revision": .number(11),
                "data": .object(["toolCallId": .string("incomplete")]),
            ])
        )
        #expect(!SessionSynchronizationCoordinator.isContiguous(
            [malformedKnown, event(sequence: 12)],
            after: .init(runtimeGeneration: "generation", eventSequence: 10)
        ))

        var mismatchedSnapshot = try SessionScenarioBuilder(seed: 53).openingTail(
            targetEncodedBytes: 8_192
        )
        mismatchedSnapshot.runtimeGeneration = "generation"
        mismatchedSnapshot.eventSequence = 11
        let mismatched = GatewayEvent(
            type: "event",
            topic: "session.snapshot",
            sessionId: "session",
            payload: try JSONValue.encode(mismatchedSnapshot)
        )
        #expect(mismatchedSnapshot.sessionId != mismatched.sessionId)
        #expect(!SessionSynchronizationCoordinator.isContiguous(
            [mismatched],
            after: .init(runtimeGeneration: "generation", eventSequence: 10)
        ))
    }

    @Test("events for other sessions remain deliverable")
    func otherSession() {
        let coordinator = SessionSynchronizationCoordinator()
        _ = coordinator.acquire(
            sessionID: "session",
            intent: .reconnect(presentationGeneration: 3)
        )
        let other = GatewayEvent(
            type: "event",
            topic: "session.progress",
            sessionId: "other",
            payload: .object([:])
        )
        #expect(coordinator.admit(other) == .deliver(other))
    }

    private func event(sequence: Int, generation: String = "generation") -> GatewayEvent {
        GatewayEvent(
            type: "event",
            topic: "session.future",
            sessionId: "session",
            payload: .object([
                "runtimeGeneration": .string(generation),
                "eventSequence": .number(Double(sequence)),
                "revision": .number(Double(sequence)),
                "data": .object([:]),
            ])
        )
    }
}
