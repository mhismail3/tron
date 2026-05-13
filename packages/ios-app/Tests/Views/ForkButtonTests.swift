import Testing
import Foundation
@testable import TronMobile

// MARK: - Fork Button State Logic Tests

@Suite("Fork Button State")
struct ForkButtonStateTests {

    // MARK: - Helpers

    private func makeEvent(
        id: String = "evt-1",
        sessionId: String = "session-1",
        type: String = "message.user",
        sequence: Int = 1
    ) -> SessionEvent {
        SessionEvent(
            id: id,
            parentId: nil,
            sessionId: sessionId,
            workspaceId: "/test",
            type: type,
            timestamp: "2026-04-12T00:00:00Z",
            sequence: sequence,
            payload: [:]
        )
    }

    // MARK: - Forkable event types

    @Test("User message events are forkable")
    func userMessageForkable() {
        let event = makeEvent(type: "message.user")
        #expect(event.isForkable == true)
    }

    @Test("Assistant message events are forkable")
    func assistantMessageForkable() {
        let event = makeEvent(type: "message.assistant")
        #expect(event.isForkable == true)
    }

    @Test("Capability invocation events are not forkable")
    func toolCallNotForkable() {
        let event = makeEvent(type: "capability.invocation.started")
        #expect(event.isForkable == false)
    }

    @Test("Capability result events are not forkable")
    func toolResultNotForkable() {
        let event = makeEvent(type: "capability.invocation.completed")
        #expect(event.isForkable == false)
    }

    @Test("Unknown event types are not forkable")
    func unknownNotForkable() {
        let event = makeEvent(type: "some.random.type")
        #expect(event.isForkable == false)
    }

    // MARK: - Fork button state derivation

    @Test("forkButtonState returns .active for forkable event in current session")
    func activeForForkableCurrentSession() {
        let event = makeEvent(sessionId: "session-1", type: "message.user")
        let state = deriveForkButtonState(
            event: event,
            sessionId: "session-1",
            isInherited: false
        )
        #expect(state == .active)
    }

    @Test("forkButtonState returns .hidden for inherited turns")
    func hiddenForInherited() {
        let event = makeEvent(sessionId: "session-1", type: "message.user")
        let state = deriveForkButtonState(
            event: event,
            sessionId: "session-1",
            isInherited: true
        )
        #expect(state == .hidden)
    }

    @Test("forkButtonState returns .hidden when event belongs to different session")
    func hiddenForDifferentSession() {
        let event = makeEvent(sessionId: "session-parent", type: "message.user")
        let state = deriveForkButtonState(
            event: event,
            sessionId: "session-child",
            isInherited: false
        )
        #expect(state == .hidden)
    }

    @Test("forkButtonState returns .hidden for non-forkable event")
    func hiddenForNonForkable() {
        let event = makeEvent(sessionId: "session-1", type: "capability.invocation.started")
        let state = deriveForkButtonState(
            event: event,
            sessionId: "session-1",
            isInherited: false
        )
        #expect(state == .hidden)
    }

    @Test("forkButtonState returns .hidden when both inherited and wrong session")
    func hiddenForInheritedAndWrongSession() {
        let event = makeEvent(sessionId: "session-parent", type: "message.assistant")
        let state = deriveForkButtonState(
            event: event,
            sessionId: "session-child",
            isInherited: true
        )
        #expect(state == .hidden)
    }
}
