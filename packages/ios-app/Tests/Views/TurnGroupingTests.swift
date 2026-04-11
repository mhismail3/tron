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

    // MARK: - Basic Grouping

    @Test("Single turn groups all events together")
    func singleTurn() {
        let events = [
            makeEvent(type: "message.user", sequence: 1, payload: makePayload(turn: 1, content: "Hello")),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(type: "tool.call", sequence: 3, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups.count == 1)
        #expect(groups[0].turnNumber == 1)
        #expect(groups[0].events.count == 3)
    }

    @Test("Multiple turns create separate groups")
    func multipleTurns() {
        let events = [
            makeEvent(type: "message.user", sequence: 1, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(type: "message.user", sequence: 3, payload: makePayload(turn: 2)),
            makeEvent(type: "tool.call", sequence: 4, payload: makePayload(turn: 2)),
            makeEvent(type: "message.assistant", sequence: 5, payload: makePayload(turn: 2)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups.count == 2)
        #expect(groups[0].turnNumber == 1)
        #expect(groups[0].events.count == 2)
        #expect(groups[1].turnNumber == 2)
        #expect(groups[1].events.count == 3)
    }

    @Test("Session events without turn go to turn 0")
    func sessionEventsInTurnZero() {
        let events = [
            makeEvent(type: "session.start", sequence: 1, payload: [:]),
            makeEvent(type: "message.user", sequence: 2, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups.count == 2)
        #expect(groups[0].turnNumber == 0)
        #expect(groups[0].events.count == 1)
        #expect(groups[1].turnNumber == 1)
    }

    @Test("Empty events returns empty result")
    func emptyEvents() {
        let groups = TurnGrouping.group(events: [], analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups.isEmpty)
    }

    @Test("Events within turn maintain original order")
    func preservesEventOrder() {
        let events = [
            makeEvent(id: "a", type: "tool.call", sequence: 1, payload: makePayload(turn: 1)),
            makeEvent(id: "b", type: "tool.result", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(id: "c", type: "message.assistant", sequence: 3, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].events.map(\.id) == ["a", "b", "c"])
    }

    @Test("Groups sorted by turn number")
    func sortedByTurnNumber() {
        let events = [
            makeEvent(type: "message.user", sequence: 5, payload: makePayload(turn: 3)),
            makeEvent(type: "message.user", sequence: 1, payload: makePayload(turn: 1)),
            makeEvent(type: "message.user", sequence: 3, payload: makePayload(turn: 2)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups.map(\.turnNumber) == [1, 2, 3])
    }

    // MARK: - User Message Preview

    @Test("Extracts user message preview from content string")
    func userMessagePreview() {
        let events = [
            makeEvent(type: "message.user", payload: makePayload(turn: 1, content: "Refactor the authentication module")),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].userMessagePreview == "Refactor the authentication module")
    }

    @Test("Truncates long user message preview to ~80 chars")
    func userMessagePreviewTruncated() {
        let longMessage = String(repeating: "a", count: 100)
        let events = [
            makeEvent(type: "message.user", payload: makePayload(turn: 1, content: longMessage)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        let preview = groups[0].userMessagePreview!
        #expect(preview.count == 80)
        #expect(preview.hasSuffix("..."))
    }

    @Test("No user message in turn returns nil preview")
    func noUserMessagePreview() {
        let events = [
            makeEvent(type: "tool.call", payload: makePayload(turn: 1)),
            makeEvent(type: "tool.result", payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].userMessagePreview == nil)
    }

    @Test("Multiline message uses first line only")
    func multilineMessagePreview() {
        let events = [
            makeEvent(type: "message.user", payload: makePayload(turn: 1, content: "First line\nSecond line\nThird line")),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].userMessagePreview == "First line")
    }

    @Test("Empty content returns nil preview")
    func emptyContentPreview() {
        let events = [
            makeEvent(type: "message.user", payload: makePayload(turn: 1, content: "")),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].userMessagePreview == nil)
    }

    // MARK: - Analytics Matching

    @Test("Matches analytics data by turn number")
    func matchesAnalyticsData() {
        // Create events that produce analytics with turn 1 data
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
            makeEvent(type: "message.user", payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: analytics, currentSessionId: "current")
        #expect(groups[0].analyticsData != nil)
        #expect(groups[0].analyticsData?.inputTokens == 100)
    }

    @Test("Missing analytics data returns nil")
    func missingAnalyticsData() {
        let events = [
            makeEvent(type: "message.user", payload: makePayload(turn: 3)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].analyticsData == nil)
    }

    // MARK: - Fork Handling

    @Test("Inherited events detected by session ID")
    func inheritedEventsDetected() {
        let events = [
            makeEvent(sessionId: "parent", type: "message.user", payload: makePayload(turn: 1)),
            makeEvent(sessionId: "parent", type: "message.assistant", payload: makePayload(turn: 1)),
            makeEvent(sessionId: "current", type: "message.user", payload: makePayload(turn: 2)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].isInherited == true)
        #expect(groups[1].isInherited == false)
    }

    @Test("Mixed session IDs in same turn — not inherited if any event is current")
    func mixedSessionInTurn() {
        // Edge case: a turn could theoretically have events from both sessions
        // (e.g., if fork happened mid-turn). If any event belongs to current, it's not inherited.
        let events = [
            makeEvent(sessionId: "parent", type: "message.user", payload: makePayload(turn: 1)),
            makeEvent(sessionId: "current", type: "message.assistant", payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")
        #expect(groups[0].isInherited == false)
    }

    // MARK: - Turn Number Extraction

    @Test("Extracts turn number from Int payload")
    func turnNumberFromInt() {
        let event = makeEvent(payload: ["turn": AnyCodable(5)])
        #expect(TurnGrouping.turnNumber(for: event) == 5)
    }

    @Test("Extracts turn number from Double payload")
    func turnNumberFromDouble() {
        let event = makeEvent(payload: ["turn": AnyCodable(3.0)])
        #expect(TurnGrouping.turnNumber(for: event) == 3)
    }

    @Test("Missing turn defaults to 0")
    func missingTurnDefaultsToZero() {
        let event = makeEvent(payload: [:])
        #expect(TurnGrouping.turnNumber(for: event) == 0)
    }

    // MARK: - Scale

    @Test("Handles many turns correctly")
    func manyTurns() {
        var events: [SessionEvent] = []
        for turn in 1...50 {
            events.append(makeEvent(
                type: "message.user",
                sequence: turn * 2 - 1,
                payload: makePayload(turn: turn, content: "Turn \(turn)")
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
}
