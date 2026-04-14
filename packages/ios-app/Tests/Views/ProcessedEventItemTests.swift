import Testing
import Foundation
@testable import TronMobile

@Suite("ProcessedEventItem")
struct ProcessedEventItemTests {

    // MARK: - Helpers

    private func makeEvent(
        id: String = UUID().uuidString,
        type: String = "message.user",
        sequence: Int = 1,
        payload: [String: AnyCodable] = [:]
    ) -> SessionEvent {
        SessionEvent(
            id: id,
            parentId: nil,
            sessionId: "test-session",
            workspaceId: "/test",
            type: type,
            timestamp: "2024-01-01T00:00:00Z",
            sequence: sequence,
            payload: payload
        )
    }

    private func makeTurn(events: [SessionEvent], turnNumber: Int = 1) -> TurnGroup {
        TurnGroup(
            turnNumber: turnNumber,
            events: events,
            analyticsData: nil,
            userMessagePreview: nil,
            assistantMessagePreview: nil,
            startsWithUserMessage: true,
            isInherited: false
        )
    }

    // MARK: - Empty Turn

    @Test("Empty turn produces empty arrays")
    func emptyTurn() {
        let turn = makeTurn(events: [])
        let (main, postTurn) = processEventsForTurn(turn)
        #expect(main.isEmpty)
        #expect(postTurn.isEmpty)
    }

    // MARK: - Single Events

    @Test("Single user message produces one item in main")
    func singleUserMessage() {
        let event = makeEvent(type: "message.user", sequence: 1)
        let turn = makeTurn(events: [event])
        let (main, postTurn) = processEventsForTurn(turn)
        #expect(main.count == 1)
        #expect(postTurn.isEmpty)
        if case .single(let e) = main[0].kind {
            #expect(e.id == event.id)
        } else {
            Issue.record("Expected .single, got .mergedTool")
        }
    }

    // MARK: - Tool Call Merging

    @Test("Tool call with matching result merges into single item")
    func toolCallWithResult() {
        let callId = "call-123"
        let callEvent = makeEvent(
            id: "evt-call",
            type: "tool.call",
            sequence: 2,
            payload: ["toolCallId": AnyCodable(callId)]
        )
        let resultEvent = makeEvent(
            id: "evt-result",
            type: "tool.result",
            sequence: 3,
            payload: ["toolCallId": AnyCodable(callId)]
        )
        let events = [
            makeEvent(type: "message.assistant", sequence: 1),
            callEvent,
            resultEvent,
        ]
        let turn = makeTurn(events: events)
        let (main, postTurn) = processEventsForTurn(turn)
        #expect(postTurn.isEmpty)

        let toolItems = main.filter {
            if case .mergedTool = $0.kind { return true }
            return false
        }
        #expect(toolItems.count == 1)

        if case .mergedTool(let call, let result) = toolItems[0].kind {
            #expect(call.id == "evt-call")
            #expect(result?.id == "evt-result")
        } else {
            Issue.record("Expected .mergedTool")
        }
    }

    @Test("In-progress tool call after completed tool goes to post-turn boundary")
    func toolCallInProgressAfterCompletedTool() {
        // When a completed tool call+result exists, a subsequent in-progress call
        // falls past the lastMainIndex (= last toolResult index) into post-turn
        let events = [
            makeEvent(type: "message.assistant", sequence: 1),
            makeEvent(id: "call-done", type: "tool.call", sequence: 2, payload: ["toolCallId": AnyCodable("done")]),
            makeEvent(id: "result-done", type: "tool.result", sequence: 3, payload: ["toolCallId": AnyCodable("done")]),
            makeEvent(id: "call-pending", type: "tool.call", sequence: 4, payload: ["toolCallId": AnyCodable("pending")]),
        ]
        let turn = makeTurn(events: events)
        let (main, _) = processEventsForTurn(turn)

        // assistant + merged(done) + merged(pending with nil result) = items in main or post-turn
        // lastMainIndex = index of last toolResult (2), so call-pending at index 3 is post-turn
        // Only assistant + merged(done) in main
        let toolItems = main.filter {
            if case .mergedTool = $0.kind { return true }
            return false
        }
        #expect(toolItems.count == 1)
        if case .mergedTool(let call, let result) = toolItems[0].kind {
            #expect(call.id == "call-done")
            #expect(result?.id == "result-done")
        }
    }

    @Test("Sole tool call without result goes to post-turn boundary")
    func soleToolCallWithoutResult() {
        // When the only tool call has no result, lastMainIndex = assistant index
        // so the tool call falls into post-turn (and gets filtered out as non-lifecycle)
        let events = [
            makeEvent(type: "message.assistant", sequence: 1),
            makeEvent(id: "evt-call", type: "tool.call", sequence: 2, payload: ["toolCallId": AnyCodable("call-456")]),
        ]
        let turn = makeTurn(events: events)
        let (main, postTurn) = processEventsForTurn(turn)

        // Only the assistant message in main (tool call is post-boundary, filtered out)
        #expect(main.count == 1)
        #expect(postTurn.isEmpty) // tool.call is not in postTurnTypes set
    }

    @Test("Tool results without matching calls are dropped from main items")
    func orphanedToolResultDropped() {
        let events = [
            makeEvent(type: "message.assistant", sequence: 1),
            makeEvent(
                id: "orphan-result",
                type: "tool.result",
                sequence: 2,
                payload: ["toolCallId": AnyCodable("nonexistent-call")]
            ),
        ]
        let turn = makeTurn(events: events)
        let (main, _) = processEventsForTurn(turn)

        // The tool result is skipped (not added as .single, and no matching call to merge with)
        #expect(main.count == 1)
        if case .single(let e) = main[0].kind {
            #expect(e.eventType == .messageAssistant)
        } else {
            Issue.record("Expected .single assistant message")
        }
    }

    // MARK: - Post-Turn Events

    @Test("Post-turn lifecycle events appear in postTurn array")
    func postTurnEvents() {
        let events = [
            makeEvent(type: "message.user", sequence: 1),
            makeEvent(type: "message.assistant", sequence: 2),
            makeEvent(id: "model-switch", type: "config.model_switch", sequence: 3),
            makeEvent(id: "commit", type: "worktree.commit", sequence: 4),
        ]
        let turn = makeTurn(events: events)
        let (main, postTurn) = processEventsForTurn(turn)

        #expect(main.count == 2) // user + assistant
        #expect(postTurn.count == 2) // model_switch + commit
    }

    @Test("Non-lifecycle events after assistant are NOT in postTurn")
    func nonLifecyclePostTurnFiltered() {
        let events = [
            makeEvent(type: "message.assistant", sequence: 1),
            // An event type not in the postTurnTypes set
            makeEvent(type: "message.user", sequence: 2),
        ]
        let turn = makeTurn(events: events)
        let (_, postTurn) = processEventsForTurn(turn)
        #expect(postTurn.isEmpty)
    }

    // MARK: - Mixed Main + Post-Turn

    @Test("Correct split between main and post-turn events")
    func mixedMainAndPostTurn() {
        let callId = "call-mixed"
        let events = [
            makeEvent(type: "message.user", sequence: 1),
            makeEvent(type: "message.assistant", sequence: 2),
            makeEvent(type: "tool.call", sequence: 3, payload: ["toolCallId": AnyCodable(callId)]),
            makeEvent(type: "tool.result", sequence: 4, payload: ["toolCallId": AnyCodable(callId)]),
            makeEvent(type: "config.model_switch", sequence: 5),
        ]
        let turn = makeTurn(events: events)
        let (main, postTurn) = processEventsForTurn(turn)

        // Main: user + assistant + merged tool = 3 items
        #expect(main.count == 3)
        // Post-turn: config.model_switch
        #expect(postTurn.count == 1)
    }

    // MARK: - Multiple Tool Calls

    @Test("Multiple sequential tool calls each correctly paired")
    func multipleToolCalls() {
        let events = [
            makeEvent(type: "message.assistant", sequence: 1),
            makeEvent(id: "call-a", type: "tool.call", sequence: 2, payload: ["toolCallId": AnyCodable("id-a")]),
            makeEvent(id: "result-a", type: "tool.result", sequence: 3, payload: ["toolCallId": AnyCodable("id-a")]),
            makeEvent(id: "call-b", type: "tool.call", sequence: 4, payload: ["toolCallId": AnyCodable("id-b")]),
            makeEvent(id: "result-b", type: "tool.result", sequence: 5, payload: ["toolCallId": AnyCodable("id-b")]),
        ]
        let turn = makeTurn(events: events)
        let (main, postTurn) = processEventsForTurn(turn)
        #expect(postTurn.isEmpty)

        // assistant + 2 merged tools = 3 items
        #expect(main.count == 3)

        let toolItems = main.compactMap { item -> (String, String?)? in
            if case .mergedTool(let call, let result) = item.kind {
                return (call.id, result?.id)
            }
            return nil
        }
        #expect(toolItems.count == 2)
        #expect(toolItems[0].0 == "call-a")
        #expect(toolItems[0].1 == "result-a")
        #expect(toolItems[1].0 == "call-b")
        #expect(toolItems[1].1 == "result-b")
    }

    @Test("In-progress tool call after completed tools goes to post-turn boundary")
    func inProgressToolCallPostBoundary() {
        // call-c at index 5 is past the lastMainIndex (last toolResult at index 4)
        let events = [
            makeEvent(type: "message.assistant", sequence: 1),
            makeEvent(id: "call-a", type: "tool.call", sequence: 2, payload: ["toolCallId": AnyCodable("id-a")]),
            makeEvent(id: "result-a", type: "tool.result", sequence: 3, payload: ["toolCallId": AnyCodable("id-a")]),
            makeEvent(id: "call-b", type: "tool.call", sequence: 4, payload: ["toolCallId": AnyCodable("id-b")]),
            makeEvent(id: "result-b", type: "tool.result", sequence: 5, payload: ["toolCallId": AnyCodable("id-b")]),
            makeEvent(id: "call-c", type: "tool.call", sequence: 6, payload: ["toolCallId": AnyCodable("id-c")]),
        ]
        let turn = makeTurn(events: events)
        let (main, postTurn) = processEventsForTurn(turn)

        // call-c goes past boundary, tool.call not in postTurnTypes → filtered out
        #expect(main.count == 3) // assistant + 2 merged completed tools
        #expect(postTurn.isEmpty) // tool.call is not a lifecycle event type
    }

    // MARK: - ID Generation

    @Test("ProcessedEventItem IDs are unique and correctly prefixed")
    func itemIds() {
        let singleEvent = makeEvent(id: "evt-1", type: "message.user")
        let callEvent = makeEvent(id: "evt-2", type: "tool.call", payload: ["toolCallId": AnyCodable("tc-1")])

        let single = ProcessedEventItem(kind: .single(singleEvent))
        let merged = ProcessedEventItem(kind: .mergedTool(call: callEvent, result: nil))

        #expect(single.id == "evt-1")
        #expect(merged.id == "tool-evt-2")
    }
}
