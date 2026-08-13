import Foundation
import Testing
@testable import TronMobile

@Suite("Session event synchronization")
struct SessionEventSynchronizerTests {
    @Test("events are quarantined and replayed after the authoritative baseline")
    func quarantinesAndReplays() {
        var synchronizer = SessionEventSynchronizer()
        let token = synchronizer.begin(sessionID: "session")
        #expect(synchronizer.admit(event(sequence: 10)) == .buffered)
        #expect(synchronizer.admit(event(sequence: 11)) == .buffered)
        let replay = synchronizer.complete(
            sessionID: "session",
            token: token,
            baseline: .init(runtimeGeneration: "generation", eventSequence: 10)
        )
        #expect(replay == [event(sequence: 11)])
    }

    @Test("a replacement runtime is replayed even when its sequence restarts")
    func replacementGeneration() {
        var synchronizer = SessionEventSynchronizer()
        let token = synchronizer.begin(sessionID: "session")
        #expect(synchronizer.admit(event(sequence: 1, generation: "replacement")) == .buffered)
        let replay = synchronizer.complete(
            sessionID: "session",
            token: token,
            baseline: .init(runtimeGeneration: "generation", eventSequence: 100)
        )
        #expect(replay == [event(sequence: 1, generation: "replacement")])
    }

    @Test("buffer overflow requires another authoritative synchronization")
    func overflow() {
        var synchronizer = SessionEventSynchronizer(maximumBufferedEvents: 2)
        let token = synchronizer.begin(sessionID: "session")
        #expect(synchronizer.admit(event(sequence: 1)) == .buffered)
        #expect(synchronizer.admit(event(sequence: 2)) == .buffered)
        #expect(synchronizer.admit(event(sequence: 3)) == .overflow("session"))
        #expect(synchronizer.complete(
            sessionID: "session",
            token: token,
            baseline: .init(runtimeGeneration: "generation", eventSequence: 0)
        ) == nil)
    }

    @Test("a failed baseline can be cancelled without disturbing its replacement")
    func cancelFailedBaseline() {
        var synchronizer = SessionEventSynchronizer()
        let failed = synchronizer.begin(sessionID: "session")
        #expect(synchronizer.admit(event(sequence: 10)) == .buffered)
        synchronizer.cancel(sessionID: "session", token: failed)
        #expect(!synchronizer.isSynchronizing(sessionID: "session"))

        let replacement = synchronizer.begin(sessionID: "session")
        synchronizer.cancel(sessionID: "session", token: failed)
        #expect(synchronizer.token(sessionID: "session") == replacement)
    }

    @Test("events for other sessions remain deliverable")
    func otherSession() {
        var synchronizer = SessionEventSynchronizer()
        _ = synchronizer.begin(sessionID: "session")
        let other = GatewayEvent(type: "event", topic: "session.progress", sessionId: "other", payload: .object([:]))
        #expect(synchronizer.admit(other) == .deliver(other))
    }

    private func event(sequence: Int, generation: String = "generation") -> GatewayEvent {
        GatewayEvent(
            type: "event",
            topic: "session.progress",
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
