import Testing
import Foundation
@testable import TronMobile

@Suite("TurnGrouping")
struct TurnGroupingTests {

    // MARK: - Helpers

    private func makeEvent(
        id: String = UUID().uuidString,
        sessionId: String = "current",
        type: String = "message.user",
        sequence: Int = 1,
        payload: [String: AnyCodable] = [:]
    ) -> SessionEvent {
        SessionEvent(
            id: id,
            parentId: nil,
            sessionId: sessionId,
            workspaceId: "/test",
            type: type,
            timestamp: "2024-01-01T00:00:00Z",
            sequence: sequence,
            payload: payload
        )
    }

    private func makePayload(turn: Int, content: String? = nil) -> [String: AnyCodable] {
        var payload: [String: AnyCodable] = ["turn": AnyCodable(turn)]
        if let content {
            payload["content"] = AnyCodable(content)
        }
        return payload
    }

    private let emptyAnalytics = ConsolidatedAnalytics(from: [])

    // MARK: - Boundary-Based Grouping

    @Test("User message + assistant + tools grouped into same turn")
    func userAndAssistantGroupedTogether() {
        let events = [
            makeEvent(type: "message.user", sequence: 1, payload: ["content": AnyCodable("Hello")]),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(type: "tool.call", sequence: 3, payload: makePayload(turn: 1)),
            makeEvent(type: "tool.result", sequence: 4, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups.count == 1)
        #expect(groups[0].turnNumber == 1)
        #expect(groups[0].events.count == 4)
        #expect(groups[0].userMessagePreview == "Hello")
    }

    @Test("Multiple turns each contain user message + assistant events")
    func multipleTurnsGroupCorrectly() {
        let events = [
            makeEvent(type: "message.user", sequence: 1, payload: ["content": AnyCodable("First")]),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(type: "tool.call", sequence: 3, payload: makePayload(turn: 1)),
            makeEvent(type: "message.user", sequence: 4, payload: ["content": AnyCodable("Second")]),
            makeEvent(type: "message.assistant", sequence: 5, payload: makePayload(turn: 2)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups.count == 2)
        #expect(groups[0].turnNumber == 1)
        #expect(groups[0].events.count == 3)
        #expect(groups[0].userMessagePreview == "First")
        #expect(groups[1].turnNumber == 2)
        #expect(groups[1].events.count == 2)
        #expect(groups[1].userMessagePreview == "Second")
    }

    @Test("Session setup events before first turn go to turn 0")
    func sessionSetupInTurnZero() {
        let events = [
            makeEvent(type: "session.start", sequence: 1),
            makeEvent(type: "worktree.acquired", sequence: 2),
            makeEvent(type: "message.user", sequence: 3, payload: ["content": AnyCodable("Hello")]),
            makeEvent(type: "message.assistant", sequence: 4, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups.count == 2)
        #expect(groups[0].turnNumber == 0)
        #expect(groups[0].events.count == 2) // session.start + worktree.acquired
        #expect(groups[1].turnNumber == 1)
        #expect(groups[1].events.count == 2) // message.user + message.assistant
    }

    @Test("Worktree/hook events between turns grouped with preceding turn")
    func interTurnEventsInheritTurn() {
        let events = [
            makeEvent(type: "message.user", sequence: 1),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(type: "worktree.commit", sequence: 3), // no turn in payload
            makeEvent(type: "message.user", sequence: 4),
            makeEvent(type: "message.assistant", sequence: 5, payload: makePayload(turn: 2)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups.count == 2)
        #expect(groups[0].events.count == 3) // user + assistant + worktree.commit
        #expect(groups[1].events.count == 2) // user + assistant
    }

    @Test("Empty events returns empty result")
    func emptyEvents() {
        let groups = TurnGrouping.group(events: [], analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups.isEmpty)
    }

    @Test("Events within turn maintain sequence order")
    func preservesEventOrder() {
        let events = [
            makeEvent(id: "a", type: "message.user", sequence: 1),
            makeEvent(id: "b", type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(id: "c", type: "tool.call", sequence: 3, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].events.map(\.id) == ["a", "b", "c"])
    }

    // MARK: - User Message Preview

    @Test("Extracts user message preview from content string")
    func userMessagePreview() {
        let events = [
            makeEvent(type: "message.user", sequence: 1, payload: ["content": AnyCodable("Refactor the auth module")]),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].userMessagePreview == "Refactor the auth module")
    }

    @Test("Truncates long user message preview to ~80 chars")
    func userMessagePreviewTruncated() {
        let longMessage = String(repeating: "a", count: 100)
        let events = [
            makeEvent(type: "message.user", sequence: 1, payload: ["content": AnyCodable(longMessage)]),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        let preview = groups[0].userMessagePreview!
        #expect(preview.count == 80)
        #expect(preview.hasSuffix("..."))
    }

    @Test("No user message in turn returns nil preview")
    func noUserMessagePreview() {
        // Session setup events with no user message
        let events = [
            makeEvent(type: "session.start", sequence: 1),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].userMessagePreview == nil)
    }

    @Test("Multiline message uses first line only")
    func multilineMessagePreview() {
        let events = [
            makeEvent(type: "message.user", sequence: 1, payload: ["content": AnyCodable("First line\nSecond line\nThird line")]),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].userMessagePreview == "First line")
    }

    @Test("Empty content returns nil preview")
    func emptyContentPreview() {
        let events = [
            makeEvent(type: "message.user", sequence: 1, payload: ["content": AnyCodable("")]),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].userMessagePreview == nil)
    }

    // MARK: - Analytics Matching

    @Test("Matches analytics data by turn number")
    func matchesAnalyticsData() {
        let tokenRecord: [String: Any] = [
            "source": [
                "rawInputTokens": 100,
                "rawOutputTokens": 200,
                "rawCacheReadTokens": 0,
                "rawCacheCreationTokens": 0,
            ]
        ]
        let analyticsEvents = [
            makeEvent(type: "message.assistant", payload: [
                "turn": AnyCodable(1),
                "tokenRecord": AnyCodable(tokenRecord),
                "latency": AnyCodable(500),
            ]),
            makeEvent(type: "stream.turn_end", payload: [
                "turn": AnyCodable(1),
                "cost": AnyCodable(0.01),
                "tokenRecord": AnyCodable(tokenRecord),
            ]),
        ]
        let analytics = ConsolidatedAnalytics(from: analyticsEvents)

        let events = [
            makeEvent(type: "message.user", sequence: 1),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: analytics, currentSessionId: "current")
        #expect(groups[0].analyticsData != nil)
        #expect(groups[0].analyticsData?.inputTokens == 100)
    }

    @Test("Missing analytics data returns nil")
    func missingAnalyticsData() {
        let events = [
            makeEvent(type: "message.user", sequence: 1),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 3)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].analyticsData == nil)
    }

    // MARK: - Fork Handling

    @Test("Inherited events detected by session ID")
    func inheritedEventsDetected() {
        let events = [
            makeEvent(sessionId: "parent", type: "message.user", sequence: 1),
            makeEvent(sessionId: "parent", type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(sessionId: "current", type: "message.user", sequence: 3),
            makeEvent(sessionId: "current", type: "message.assistant", sequence: 4, payload: makePayload(turn: 2)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups.count == 2)
        // Turn 1: parent events only → inherited
        #expect(groups[0].turnNumber == 1)
        #expect(groups[0].events.count == 2)
        #expect(groups[0].events.allSatisfy { $0.sessionId == "parent" })
        #expect(groups[0].isInherited == true)
        // Turn 2: current events only → not inherited
        #expect(groups[1].turnNumber == 2)
        #expect(groups[1].isInherited == false)
    }

    // MARK: - Scale

    @Test("Handles many turns correctly")
    func manyTurns() {
        var events: [SessionEvent] = []
        for turn in 1...50 {
            events.append(makeEvent(
                type: "message.user",
                sequence: turn * 2 - 1,
                payload: ["content": AnyCodable("Turn \(turn)")]
            ))
            events.append(makeEvent(
                type: "message.assistant",
                sequence: turn * 2,
                payload: makePayload(turn: turn)
            ))
        }
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups.count == 50)
        #expect(groups.first?.turnNumber == 1)
        #expect(groups.last?.turnNumber == 50)
    }

    // MARK: - Realistic Scenario

    @Test("Full session with setup, multiple turns, hooks, and worktree events")
    func realisticSession() {
        let events = [
            // Session setup
            makeEvent(type: "session.start", sequence: 1),
            makeEvent(type: "worktree.acquired", sequence: 2),
            // Turn 1
            makeEvent(type: "message.user", sequence: 3, payload: ["content": AnyCodable("Create test files")]),
            makeEvent(type: "message.assistant", sequence: 4, payload: makePayload(turn: 1)),
            makeEvent(type: "tool.call", sequence: 5, payload: makePayload(turn: 1)),
            makeEvent(type: "tool.result", sequence: 6, payload: makePayload(turn: 1)),
            makeEvent(type: "tool.call", sequence: 7, payload: makePayload(turn: 1)),
            makeEvent(type: "tool.result", sequence: 8, payload: makePayload(turn: 1)),
            // Hook between turns (no turn in payload)
            makeEvent(type: "hook.result", sequence: 9),
            makeEvent(type: "worktree.commit", sequence: 10),
            // Turn 2
            makeEvent(type: "message.user", sequence: 11, payload: ["content": AnyCodable("Now edit them")]),
            makeEvent(type: "message.assistant", sequence: 12, payload: makePayload(turn: 2)),
            makeEvent(type: "tool.call", sequence: 13, payload: makePayload(turn: 2)),
            makeEvent(type: "tool.result", sequence: 14, payload: makePayload(turn: 2)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        #expect(groups.count == 3) // turn 0 (setup), turn 1, turn 2

        // Turn 0: session.start + worktree.acquired
        #expect(groups[0].turnNumber == 0)
        #expect(groups[0].events.count == 2)

        // Turn 1: user + assistant + 2 tool calls + 2 tool results + hook + worktree.commit
        #expect(groups[1].turnNumber == 1)
        #expect(groups[1].events.count == 8)
        #expect(groups[1].userMessagePreview == "Create test files")

        // Turn 2: user + assistant + tool call + tool result
        #expect(groups[2].turnNumber == 2)
        #expect(groups[2].events.count == 4)
        #expect(groups[2].userMessagePreview == "Now edit them")
    }
}
