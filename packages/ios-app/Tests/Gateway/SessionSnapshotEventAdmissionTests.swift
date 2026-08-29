import Testing
@testable import TronMobile

@Suite("Live session snapshot admission")
struct SessionSnapshotEventAdmissionTests {
    @Test("only the exact next cursor for the installed runtime may update live state")
    func exactNextCursor() throws {
        let current = try SessionScenarioBuilder(seed: 51).openingTail(targetEncodedBytes: 8_192)

        var stale = current
        stale.eventSequence -= 1
        #expect(admission(current: current, incoming: stale) == .ignore)

        var duplicate = current
        duplicate.phase = .running
        duplicate.name = "same cursor must not replace"
        #expect(admission(current: current, incoming: duplicate) == .ignore)

        var next = current
        next.eventSequence += 1
        #expect(admission(current: current, incoming: next) == .install)

        var gap = current
        gap.eventSequence += 2
        #expect(admission(current: current, incoming: gap) == .resynchronize(current.sessionId))
    }

    @Test("an exact-next snapshot missing a known activity revision rebaselines")
    func missingLiveActivityRevisionRequiresAuthority() throws {
        let current = try SessionScenarioBuilder(seed: 54).openingTail(targetEncodedBytes: 8_192)
        var installed = current
        installed.liveActivityRevision = 4
        var missing = installed
        missing.eventSequence += 1
        missing.liveActivityRevision = nil
        #expect(admission(current: installed, incoming: missing) == .resynchronize(current.sessionId))

        var bothMissing = current
        bothMissing.liveActivityRevision = nil
        var next = bothMissing
        next.eventSequence += 1
        #expect(admission(current: bothMissing, incoming: next) == .install)
    }

    @Test("older live activity revisions cannot resurrect a delayed projection")
    func staleLiveActivityProjection() throws {
        let current = try SessionScenarioBuilder(seed: 53).openingTail(targetEncodedBytes: 8_192)
        var installed = current
        installed.eventSequence += 1
        installed.liveActivityRevision = 4
        installed.extensionActivityAsOf = "2026-01-01T00:00:04Z"
        var stale = installed
        stale.eventSequence += 1
        stale.liveActivityRevision = 3
        stale.extensionActivityAsOf = "2026-01-01T00:00:03Z"
        #expect(admission(current: installed, incoming: stale) == .resynchronize(current.sessionId))
    }

    @Test("queue admission is bounded and rejects duplicate or empty identities")
    func queueAdmission() throws {
        var snapshot = try SessionScenarioBuilder(seed: 55).openingTail(targetEncodedBytes: 8_192)
        snapshot.queuedItems = (0..<SessionSnapshot.maximumQueuedMessages).map {
            .init(id: "queue-\($0)", behavior: .steer, text: "item", attachmentCount: 0)
        }
        #expect(SessionSnapshotQueueAdmissionPolicy.admit(snapshot))

        snapshot.queuedItems.append(
            .init(id: "overflow", behavior: .followUp, text: "overflow", attachmentCount: 0)
        )
        #expect(!SessionSnapshotQueueAdmissionPolicy.admit(snapshot))

        snapshot.queuedItems = [
            .init(id: "duplicate", behavior: .steer, text: "a", attachmentCount: 0),
            .init(id: "duplicate", behavior: .followUp, text: "b", attachmentCount: 0),
        ]
        #expect(!SessionSnapshotQueueAdmissionPolicy.admit(snapshot))
        snapshot.queuedItems = [
            .init(id: "", behavior: .steer, text: "empty", attachmentCount: 0)
        ]
        #expect(!SessionSnapshotQueueAdmissionPolicy.admit(snapshot))
    }

    @Test("same-runtime rebaseline preserves activity monotonicity")
    func rebaselineActivityAdmission() throws {
        var current = try SessionScenarioBuilder(seed: 56).openingTail(targetEncodedBytes: 8_192)
        current.liveActivityRevision = 4

        var newer = current
        newer.eventSequence += 2
        newer.liveActivityRevision = 5
        #expect(SessionRebaselineAdmission.evaluate(current: current, incoming: newer) == .install)

        var missing = newer
        missing.liveActivityRevision = nil
        #expect(SessionRebaselineAdmission.evaluate(current: current, incoming: missing) == .resynchronize)

        var regressed = newer
        regressed.liveActivityRevision = 3
        #expect(SessionRebaselineAdmission.evaluate(current: current, incoming: regressed) == .resynchronize)

        var duplicate = current
        duplicate.liveActivityRevision = 5
        #expect(SessionRebaselineAdmission.evaluate(current: current, incoming: duplicate) == .ignore)

        var replacement = newer
        replacement.runtimeGeneration = "replacement"
        replacement.liveActivityRevision = nil
        #expect(SessionRebaselineAdmission.evaluate(current: current, incoming: replacement) == .install)
    }

    @Test("missing baselines, runtime replacement, and route-payload mismatch require authority")
    func authorityBoundaries() throws {
        let current = try SessionScenarioBuilder(seed: 52).openingTail(targetEncodedBytes: 8_192)
        var replacement = current
        replacement.runtimeGeneration = "replacement"
        replacement.eventSequence = 1

        #expect(SessionSnapshotEventAdmission.evaluate(
            eventSessionID: current.sessionId,
            hasLiveAuthority: true,
            current: nil,
            incoming: current
        ) == .resynchronize(current.sessionId))
        #expect(admission(current: current, incoming: replacement) == .resynchronize(current.sessionId))
        #expect(SessionSnapshotEventAdmission.evaluate(
            eventSessionID: "other-session",
            hasLiveAuthority: true,
            current: current,
            incoming: current
        ) == .resynchronize("other-session"))
        #expect(SessionSnapshotEventAdmission.evaluate(
            eventSessionID: nil,
            hasLiveAuthority: true,
            current: current,
            incoming: current
        ) == .ignore)
        var next = current
        next.eventSequence += 1
        #expect(SessionSnapshotEventAdmission.evaluate(
            eventSessionID: current.sessionId,
            hasLiveAuthority: false,
            current: current,
            incoming: next
        ) == .ignore)
    }

    private func admission(
        current: SessionSnapshot,
        incoming: SessionSnapshot
    ) -> SessionSnapshotEventAdmission {
        SessionSnapshotEventAdmission.evaluate(
            eventSessionID: current.sessionId,
            hasLiveAuthority: true,
            current: current,
            incoming: incoming
        )
    }
}
