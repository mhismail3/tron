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

    // MARK: - Prompt Cycle Turn Reset
    //
    // The Rust agent resets the `turn` payload field to 1 at the start of each
    // new user prompt cycle. These tests verify that TurnGrouping produces
    // globally unique, monotonically increasing turn numbers across resets.

    @Test("Two prompt cycles with turn reset produce unique sequential groups")
    func turnResetAcrossPromptCycles() {
        let events = [
            // Prompt cycle 1: turns 1-3
            makeEvent(type: "message.user", sequence: 1, payload: ["content": AnyCodable("First prompt")]),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 3, payload: makePayload(turn: 2)),
            makeEvent(type: "message.assistant", sequence: 4, payload: makePayload(turn: 3)),
            // Prompt cycle 2: turns reset to 1-2
            makeEvent(type: "message.user", sequence: 5, payload: ["content": AnyCodable("Second prompt")]),
            makeEvent(type: "message.assistant", sequence: 6, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 7, payload: makePayload(turn: 2)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        #expect(groups.count == 5)
        #expect(groups[0].turnNumber == 1)
        #expect(groups[0].userMessagePreview == "First prompt")
        #expect(groups[1].turnNumber == 2)
        #expect(groups[2].turnNumber == 3)
        #expect(groups[3].turnNumber == 4)
        #expect(groups[3].userMessagePreview == "Second prompt")
        #expect(groups[4].turnNumber == 5)
    }

    @Test("Three prompt cycles with turn resets produce correct sequential turns")
    func threePromptCyclesWithReset() {
        let events = [
            // Cycle 1: turns 1-2
            makeEvent(type: "message.user", sequence: 1),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 3, payload: makePayload(turn: 2)),
            // Cycle 2: reset to turn 1
            makeEvent(type: "message.user", sequence: 4),
            makeEvent(type: "message.assistant", sequence: 5, payload: makePayload(turn: 1)),
            // Cycle 3: reset to turns 1-3
            makeEvent(type: "message.user", sequence: 6),
            makeEvent(type: "message.assistant", sequence: 7, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 8, payload: makePayload(turn: 2)),
            makeEvent(type: "message.assistant", sequence: 9, payload: makePayload(turn: 3)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        #expect(groups.count == 6)
        let turnNumbers = groups.map(\.turnNumber)
        #expect(turnNumbers == [1, 2, 3, 4, 5, 6])
    }

    @Test("Single-turn prompt followed by reset (turn=1 then turn=1)")
    func singleTurnPromptFollowedByReset() {
        let events = [
            // Cycle 1: single turn
            makeEvent(type: "message.user", sequence: 1, payload: ["content": AnyCodable("Quick question")]),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            // Cycle 2: also starts at turn=1
            makeEvent(type: "message.user", sequence: 3, payload: ["content": AnyCodable("Follow-up")]),
            makeEvent(type: "message.assistant", sequence: 4, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        #expect(groups.count == 2)
        #expect(groups[0].turnNumber == 1)
        #expect(groups[0].userMessagePreview == "Quick question")
        #expect(groups[1].turnNumber == 2)
        #expect(groups[1].userMessagePreview == "Follow-up")
    }

    @Test("Continuous turn numbering does not trigger false reset")
    func resetDoesNotTriggerForContinuousTurns() {
        // Sessions where turns already increment globally (no reset)
        let events = [
            makeEvent(type: "message.user", sequence: 1),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(type: "message.user", sequence: 3),
            makeEvent(type: "message.assistant", sequence: 4, payload: makePayload(turn: 2)),
            makeEvent(type: "message.user", sequence: 5),
            makeEvent(type: "message.assistant", sequence: 6, payload: makePayload(turn: 3)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        #expect(groups.count == 3)
        #expect(groups[0].turnNumber == 1)
        #expect(groups[1].turnNumber == 2)
        #expect(groups[2].turnNumber == 3)
    }

    @Test("Inter-prompt events inherit previous cycle's last turn across reset")
    func interPromptEventsInheritPreviousTurnAcrossReset() {
        let events = [
            // Cycle 1
            makeEvent(type: "message.user", sequence: 1),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 3, payload: makePayload(turn: 2)),
            // Inter-prompt events (no turn in payload)
            makeEvent(type: "hook.llm_result", sequence: 4),
            makeEvent(type: "process.results_consumed", sequence: 5),
            // Cycle 2: reset
            makeEvent(type: "message.user", sequence: 6),
            makeEvent(type: "message.assistant", sequence: 7, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        // Turn 1, Turn 2 (includes inter-prompt events), Turn 3 (new cycle)
        #expect(groups.count == 3)
        #expect(groups[0].turnNumber == 1)
        #expect(groups[0].events.count == 2) // user + assistant
        #expect(groups[1].turnNumber == 2)
        #expect(groups[1].events.count == 3) // assistant + hook + process
        #expect(groups[2].turnNumber == 3)
        #expect(groups[2].events.count == 2) // user + assistant
    }

    @Test("Reset with setup events preserves turn zero")
    func resetWithSetupEventsPreservesTurnZero() {
        let events = [
            // Setup
            makeEvent(type: "session.start", sequence: 1),
            makeEvent(type: "worktree.acquired", sequence: 2),
            // Cycle 1: turns 1-3
            makeEvent(type: "message.user", sequence: 3),
            makeEvent(type: "message.assistant", sequence: 4, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 5, payload: makePayload(turn: 2)),
            makeEvent(type: "message.assistant", sequence: 6, payload: makePayload(turn: 3)),
            // Cycle 2: reset
            makeEvent(type: "message.user", sequence: 7),
            makeEvent(type: "message.assistant", sequence: 8, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 9, payload: makePayload(turn: 2)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        #expect(groups.count == 6) // turn 0 + 3 from cycle 1 + 2 from cycle 2
        #expect(groups[0].turnNumber == 0) // setup
        #expect(groups[0].events.count == 2)
        #expect(groups[1].turnNumber == 1)
        #expect(groups[2].turnNumber == 2)
        #expect(groups[3].turnNumber == 3)
        #expect(groups[4].turnNumber == 4) // cycle 2, raw turn 1
        #expect(groups[5].turnNumber == 5) // cycle 2, raw turn 2
    }

    @Test("User message with no subsequent turn at cycle end")
    func userMessageWithNoSubsequentTurnAtCycleEnd() {
        let events = [
            makeEvent(type: "message.user", sequence: 1),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            // User sends another message but session ends before assistant responds
            makeEvent(type: "message.user", sequence: 3, payload: ["content": AnyCodable("Pending")]),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        #expect(groups.count == 2)
        #expect(groups[0].turnNumber == 1)
        #expect(groups[1].turnNumber == 2)
        #expect(groups[1].userMessagePreview == "Pending")
    }

    @Test("Reset detected via explicit turn fallback without user message")
    func resetWithExplicitTurnFallback() {
        // Two assistant messages where turn resets without an intervening user message
        // (e.g., auto-continuation or cron-triggered cycle)
        let events = [
            makeEvent(type: "message.assistant", sequence: 1, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 2)),
            makeEvent(type: "message.assistant", sequence: 3, payload: makePayload(turn: 3)),
            // Reset without user message
            makeEvent(type: "message.assistant", sequence: 4, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 5, payload: makePayload(turn: 2)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        #expect(groups.count == 5)
        let turnNumbers = groups.map(\.turnNumber)
        // Must be monotonically increasing, no collisions
        #expect(turnNumbers == [1, 2, 3, 4, 5])
    }

    // MARK: - ID and Ordering Invariants

    @Test("All group IDs unique across prompt cycle resets")
    func allGroupIdsUniqueAcrossResets() {
        let events = [
            makeEvent(type: "message.user", sequence: 1),
            makeEvent(type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 3, payload: makePayload(turn: 2)),
            makeEvent(type: "message.user", sequence: 4),
            makeEvent(type: "message.assistant", sequence: 5, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 6, payload: makePayload(turn: 2)),
            makeEvent(type: "message.user", sequence: 7),
            makeEvent(type: "message.assistant", sequence: 8, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        let ids = groups.map(\.id)
        #expect(Set(ids).count == ids.count, "Group IDs must be unique, got: \(ids)")
    }

    @Test("Turn numbers monotonically increasing across resets")
    func turnNumbersMonotonicallyIncreasingAcrossResets() {
        let events = [
            makeEvent(type: "session.start", sequence: 1),
            makeEvent(type: "message.user", sequence: 2),
            makeEvent(type: "message.assistant", sequence: 3, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 4, payload: makePayload(turn: 2)),
            makeEvent(type: "message.assistant", sequence: 5, payload: makePayload(turn: 3)),
            makeEvent(type: "message.user", sequence: 6),
            makeEvent(type: "message.assistant", sequence: 7, payload: makePayload(turn: 1)),
            makeEvent(type: "message.assistant", sequence: 8, payload: makePayload(turn: 2)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        let turnNumbers = groups.map(\.turnNumber)
        for i in 1..<turnNumbers.count {
            #expect(turnNumbers[i] > turnNumbers[i - 1],
                    "Turn \(turnNumbers[i]) at index \(i) must be > turn \(turnNumbers[i - 1]) at index \(i - 1)")
        }
    }

    // MARK: - Analytics Integration with Reset

    @Test("Analytics data maps correctly across prompt cycle resets")
    func analyticsMapCorrectlyAcrossResets() {
        let tokenRecord1: [String: Any] = ["source": ["rawInputTokens": 100, "rawOutputTokens": 200, "rawCacheReadTokens": 0, "rawCacheCreationTokens": 0]]
        let tokenRecord2: [String: Any] = ["source": ["rawInputTokens": 300, "rawOutputTokens": 400, "rawCacheReadTokens": 0, "rawCacheCreationTokens": 0]]

        // Events used for both analytics and grouping
        let allEvents: [SessionEvent] = [
            // Cycle 1
            makeEvent(type: "message.user", sequence: 1),
            makeEvent(type: "message.assistant", sequence: 2, payload: [
                "turn": AnyCodable(1), "tokenRecord": AnyCodable(tokenRecord1), "latency": AnyCodable(500)
            ]),
            makeEvent(type: "stream.turn_end", sequence: 3, payload: [
                "turn": AnyCodable(1), "cost": AnyCodable(0.01), "tokenRecord": AnyCodable(tokenRecord1)
            ]),
            // Cycle 2: reset
            makeEvent(type: "message.user", sequence: 4),
            makeEvent(type: "message.assistant", sequence: 5, payload: [
                "turn": AnyCodable(1), "tokenRecord": AnyCodable(tokenRecord2), "latency": AnyCodable(800)
            ]),
            makeEvent(type: "stream.turn_end", sequence: 6, payload: [
                "turn": AnyCodable(1), "cost": AnyCodable(0.05), "tokenRecord": AnyCodable(tokenRecord2)
            ]),
        ]
        let analytics = ConsolidatedAnalytics(from: allEvents)

        // Filter out stream events (as AgentControlView does)
        let filteredEvents = allEvents.filter { event in
            let type = SessionEventType(rawValue: event.type)
            return type != .streamTurnEnd && type != .streamTurnStart
        }
        let groups = TurnGrouping.group(events: filteredEvents, analytics: analytics, currentSessionId: "current")

        #expect(groups.count == 2)
        // First group (global turn 1) should have analytics from cycle 1
        #expect(groups[0].analyticsData != nil)
        #expect(groups[0].analyticsData?.inputTokens == 100)
        #expect(groups[0].analyticsData?.outputTokens == 200)
        // Second group (global turn 2) should have analytics from cycle 2
        #expect(groups[1].analyticsData != nil)
        #expect(groups[1].analyticsData?.inputTokens == 300)
        #expect(groups[1].analyticsData?.outputTokens == 400)
    }

    // MARK: - Fork + Reset

    @Test("Forked session with turn reset in current turns preserves isInherited")
    func forkedSessionWithResetInCurrentTurns() {
        let events = [
            // Parent session (inherited)
            makeEvent(sessionId: "parent", type: "message.user", sequence: 1),
            makeEvent(sessionId: "parent", type: "message.assistant", sequence: 2, payload: makePayload(turn: 1)),
            makeEvent(sessionId: "parent", type: "message.assistant", sequence: 3, payload: makePayload(turn: 2)),
            // Current session: turns reset
            makeEvent(sessionId: "current", type: "message.user", sequence: 4),
            makeEvent(sessionId: "current", type: "message.assistant", sequence: 5, payload: makePayload(turn: 1)),
            makeEvent(sessionId: "current", type: "message.user", sequence: 6),
            makeEvent(sessionId: "current", type: "message.assistant", sequence: 7, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        // Should have 4 groups: inherited 1, inherited 2, current 3, current 4
        #expect(groups.count == 4)
        #expect(groups[0].isInherited == true)
        #expect(groups[1].isInherited == true)
        #expect(groups[2].isInherited == false)
        #expect(groups[3].isInherited == false)

        // All IDs unique (no "c1" collision)
        let ids = groups.map(\.id)
        #expect(Set(ids).count == ids.count, "IDs must be unique in forked+reset session, got: \(ids)")
    }

    // MARK: - Scale with Reset

    @Test("Many prompt cycles with reset maintain correctness")
    func manyPromptCyclesWithReset() {
        var events: [SessionEvent] = []
        var seq = 1

        // 20 prompt cycles, each with 2-3 turns that reset
        for cycle in 0..<20 {
            events.append(makeEvent(type: "message.user", sequence: seq))
            seq += 1
            let turnsInCycle = (cycle % 2 == 0) ? 2 : 3
            for turn in 1...turnsInCycle {
                events.append(makeEvent(type: "message.assistant", sequence: seq, payload: makePayload(turn: turn)))
                seq += 1
            }
        }

        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        // Expected: 10 cycles × 2 turns + 10 cycles × 3 turns = 50 total turns
        let expectedTurns = 10 * 2 + 10 * 3
        #expect(groups.count == expectedTurns)

        // All IDs unique
        let ids = groups.map(\.id)
        #expect(Set(ids).count == ids.count)

        // Monotonically increasing
        let turnNumbers = groups.map(\.turnNumber)
        for i in 1..<turnNumbers.count {
            #expect(turnNumbers[i] > turnNumbers[i - 1])
        }
    }

    // MARK: - Realistic Multi-Prompt Session

    @Test("Realistic session matching actual database patterns with tools and inter-prompt events")
    func realisticMultiPromptSession() {
        let events = [
            // Session setup
            makeEvent(type: "session.start", sequence: 0),
            makeEvent(type: "skill.activated", sequence: 1),
            makeEvent(type: "worktree.acquired", sequence: 2),
            // Prompt 1: 3 turns with tool calls
            makeEvent(type: "message.user", sequence: 3, payload: ["content": AnyCodable("Ingest all of them into the knowledge base")]),
            makeEvent(type: "hook.llm_result", sequence: 4),
            makeEvent(type: "message.assistant", sequence: 5, payload: makePayload(turn: 1)),
            makeEvent(type: "tool.call", sequence: 6, payload: makePayload(turn: 1)),
            makeEvent(type: "tool.result", sequence: 7),
            makeEvent(type: "message.assistant", sequence: 8, payload: makePayload(turn: 2)),
            makeEvent(type: "tool.call", sequence: 9, payload: makePayload(turn: 2)),
            makeEvent(type: "tool.result", sequence: 10),
            makeEvent(type: "message.assistant", sequence: 11, payload: makePayload(turn: 3)),
            // Inter-prompt events
            makeEvent(type: "hook.llm_result", sequence: 12),
            makeEvent(type: "process.results_consumed", sequence: 13),
            // Prompt 2: 2 turns, turn numbers reset
            makeEvent(type: "message.user", sequence: 14, payload: ["content": AnyCodable("Now tag all bookmarks")]),
            makeEvent(type: "message.assistant", sequence: 15, payload: makePayload(turn: 1)),
            makeEvent(type: "tool.call", sequence: 16, payload: makePayload(turn: 1)),
            makeEvent(type: "notification.process_result", sequence: 17),
            makeEvent(type: "tool.result", sequence: 18),
            makeEvent(type: "message.assistant", sequence: 19, payload: makePayload(turn: 2)),
            // Inter-prompt events
            makeEvent(type: "hook.llm_result", sequence: 20),
            // Prompt 3: 1 turn, reset again
            makeEvent(type: "message.user", sequence: 21, payload: ["content": AnyCodable("Done. Commit everything")]),
            makeEvent(type: "message.assistant", sequence: 22, payload: makePayload(turn: 1)),
        ]
        let groups = TurnGrouping.group(events: events, analytics: emptyAnalytics, currentSessionId: "current")

        // Turn 0: setup (3 events)
        // Turn 1-3: prompt 1 (user + hook + 3 assistants + 2 tools + 2 results + 2 inter-prompt)
        // Turn 4-5: prompt 2 (user + 2 assistants + tool + notification + result + hook)
        // Turn 6: prompt 3 (user + assistant)
        #expect(groups[0].turnNumber == 0)
        #expect(groups[0].events.count == 3) // session.start + skill.activated + worktree.acquired

        // Prompt 1 turns
        #expect(groups[1].turnNumber == 1)
        #expect(groups[1].userMessagePreview == "Ingest all of them into the knowledge base")
        #expect(groups[2].turnNumber == 2)
        #expect(groups[3].turnNumber == 3)

        // Prompt 2 turns (global turns 4-5, raw turns were 1-2)
        #expect(groups[4].turnNumber == 4)
        #expect(groups[4].userMessagePreview == "Now tag all bookmarks")
        #expect(groups[5].turnNumber == 5)

        // Prompt 3 turn (global turn 6, raw turn was 1)
        #expect(groups[6].turnNumber == 6)
        #expect(groups[6].userMessagePreview == "Done. Commit everything")

        #expect(groups.count == 7) // turn 0 + 3 + 2 + 1

        // All IDs unique
        let ids = groups.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
