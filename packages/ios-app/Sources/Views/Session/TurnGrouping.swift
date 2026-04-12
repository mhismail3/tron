import Foundation

// MARK: - Turn Group Model

struct TurnGroup: Identifiable, Equatable {
    let turnNumber: Int
    let events: [SessionEvent]
    let analyticsData: ConsolidatedAnalytics.TurnData?
    let userMessagePreview: String?
    let assistantMessagePreview: String?
    let startsWithUserMessage: Bool
    let isInherited: Bool

    /// Composite ID prevents collisions in forked sessions where inherited and
    /// current turns can share the same turn number.
    var id: String { "\(isInherited ? "i" : "c")\(turnNumber)" }

    /// Best available preview text for this turn.
    var displayPreview: String? {
        userMessagePreview ?? assistantMessagePreview
    }

    static func == (lhs: TurnGroup, rhs: TurnGroup) -> Bool {
        lhs.turnNumber == rhs.turnNumber
            && lhs.events.map(\.id) == rhs.events.map(\.id)
            && lhs.isInherited == rhs.isInherited
    }
}

// MARK: - Turn Grouping Logic

enum TurnGrouping {

    /// Groups events into turns using boundary-based grouping with cycle-aware
    /// turn number correction.
    ///
    /// ## Why raw turn numbers collide
    ///
    /// The Rust agent numbers turns **per prompt cycle** — each `message.user`
    /// starts a new cycle where the `turn` payload field counts from 1. A session
    /// with three user prompts might have raw turns `[1,2,3, 1,2, 1,2,3,4]`.
    /// Using these directly would create duplicate groups and SwiftUI ID collisions.
    ///
    /// ## How correction works
    ///
    /// A cumulative `turnOffset` increases at each cycle boundary (detected when
    /// a raw turn number resets). The global turn number is `turnOffset + rawTurn`,
    /// producing a monotonically increasing sequence: `[1,2,3, 4,5, 6,7,8,9]`.
    ///
    /// ## Output invariants
    ///
    /// - Turn 0 is reserved for session setup events (before any user message)
    /// - Global turn numbers are monotonically increasing
    /// - Each contiguous run of the same global turn number forms one TurnGroup
    /// - Sessions without turn resets produce identical output to raw turn numbers
    static func group(
        events: [SessionEvent],
        analytics: ConsolidatedAnalytics,
        currentSessionId: String
    ) -> [TurnGroup] {
        guard !events.isEmpty else { return [] }

        let sorted = events.sorted { $0.sequence < $1.sequence }
        let turnAssignments = assignTurnNumbers(sorted)

        // Group events by assigned turn number, preserving order
        var turnMap: [(Int, [SessionEvent])] = []
        var currentTurn: Int? = nil
        var currentEvents: [SessionEvent] = []

        for (event, turn) in zip(sorted, turnAssignments) {
            if turn != currentTurn {
                if let ct = currentTurn {
                    turnMap.append((ct, currentEvents))
                }
                currentTurn = turn
                currentEvents = [event]
            } else {
                currentEvents.append(event)
            }
        }
        if let ct = currentTurn {
            turnMap.append((ct, currentEvents))
        }

        // Build analytics lookup by turn number
        let analyticsMap: [Int: ConsolidatedAnalytics.TurnData] = Dictionary(
            uniqueKeysWithValues: analytics.turns.map { ($0.turn, $0) }
        )

        return turnMap.map { (turn, turnEvents) in
            let userPreview = extractUserMessagePreview(from: turnEvents)
            let assistantPreview = extractAssistantMessagePreview(from: turnEvents)
            let startsWithUser = turnEvents.first?.eventType == .messageUser
            let isInherited = turnEvents.allSatisfy { $0.sessionId != currentSessionId }

            return TurnGroup(
                turnNumber: turn,
                events: turnEvents,
                analyticsData: analyticsMap[turn],
                userMessagePreview: userPreview,
                assistantMessagePreview: assistantPreview,
                startsWithUserMessage: startsWithUser,
                isInherited: isInherited
            )
        }
    }

    /// Assigns a session-global turn number to each event in sequence order.
    ///
    /// The Rust agent numbers turns per prompt cycle (each `message.user` starts
    /// a new cycle where turns count from 1). This method transforms per-cycle
    /// turn numbers into globally unique, monotonically increasing turn numbers
    /// for the entire session.
    ///
    /// Returns an array parallel to `events` with the assigned global turn number.
    ///
    /// ## Invariants
    /// - Turn 0 is reserved for session setup events (before any user message)
    /// - Global turn numbers are monotonically increasing
    /// - Each contiguous run of the same global turn number forms one TurnGroup
    /// - Sessions without turn resets produce identical output to raw turn numbers
    private static func assignTurnNumbers(_ events: [SessionEvent]) -> [Int] {
        var assignments = [Int](repeating: 0, count: events.count)
        var currentGlobalTurn = 0
        var turnOffset = 0      // cumulative offset from previous prompt cycles
        var prevRawTurn = 0     // highest raw turn in the current prompt cycle

        // Pass 1: index events that carry an explicit turn number in their payload.
        var explicitTurns: [Int: Int] = [:] // event index → raw turn number
        for (i, event) in events.enumerated() {
            if let turn = extractPayloadTurn(event), turn > 0 {
                explicitTurns[i] = turn
            }
        }

        // Pass 2: assign global turn numbers, detecting cycle boundaries.
        for i in 0..<events.count {
            let event = events[i]

            if event.eventType == .messageUser {
                // User message starts a potential new prompt cycle.
                // Look ahead to see what raw turn the next assistant message carries.
                let nextRawTurn = lookAheadForTurn(
                    from: i + 1, events: events, explicitTurns: explicitTurns
                )
                if let next = nextRawTurn {
                    if next <= prevRawTurn {
                        // Cycle boundary: raw turn reset detected.
                        // Shift offset so new cycle continues from current high-water mark.
                        turnOffset = currentGlobalTurn
                        prevRawTurn = 0
                    }
                    prevRawTurn = next
                    currentGlobalTurn = turnOffset + next
                    assignments[i] = currentGlobalTurn
                } else {
                    // No future turn found (user message at end of session)
                    currentGlobalTurn += 1
                    assignments[i] = currentGlobalTurn
                }
            } else if let rawTurn = explicitTurns[i] {
                // Explicit turn in payload.
                // Guard against cycle boundaries missed by user-message detection
                // (e.g., auto-continuations without a preceding message.user).
                if rawTurn < prevRawTurn {
                    turnOffset = currentGlobalTurn
                }
                prevRawTurn = rawTurn
                currentGlobalTurn = turnOffset + rawTurn
                assignments[i] = currentGlobalTurn
            } else {
                // No turn signal — inherit the current global turn.
                assignments[i] = currentGlobalTurn
            }
        }

        return assignments
    }

    /// Look ahead from `startIndex` for the next event with an explicit turn number.
    private static func lookAheadForTurn(
        from startIndex: Int,
        events: [SessionEvent],
        explicitTurns: [Int: Int]
    ) -> Int? {
        for i in startIndex..<events.count {
            if let turn = explicitTurns[i] {
                return turn
            }
            // Stop looking if we hit another user message (that's a different turn)
            if events[i].eventType == .messageUser {
                return nil
            }
        }
        return nil
    }

    /// Extract turn number from event payload if present and positive.
    private static func extractPayloadTurn(_ event: SessionEvent) -> Int? {
        if let turn = event.payload["turn"]?.value as? Int, turn > 0 {
            return turn
        }
        if let turn = event.payload["turn"]?.value as? Double, turn > 0 {
            return Int(turn)
        }
        return nil
    }

    /// Extracts first ~80 chars of user message content from events in a turn.
    static func extractUserMessagePreview(from events: [SessionEvent]) -> String? {
        extractMessagePreview(from: events, eventType: .messageUser)
    }

    /// Extracts first ~80 chars of assistant message content from events in a turn.
    static func extractAssistantMessagePreview(from events: [SessionEvent]) -> String? {
        extractMessagePreview(from: events, eventType: .messageAssistant)
    }

    /// Extracts first ~80 chars of message content for a given event type.
    private static func extractMessagePreview(from events: [SessionEvent], eventType: SessionEventType) -> String? {
        for event in events {
            guard event.eventType == eventType else { continue }

            // Try content as a plain string
            if let content = event.payload["content"]?.value as? String, !content.isEmpty {
                return truncatePreview(content)
            }

            // Try content array format (array of blocks with text)
            if let contentArray = event.payload["content"]?.value as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_use" { continue }
                    if let text = block["text"] as? String, !text.isEmpty {
                        return truncatePreview(text)
                    }
                }
            }
        }
        return nil
    }

    private static func truncatePreview(_ text: String) -> String {
        let firstLine = text.components(separatedBy: .newlines).first ?? text
        if firstLine.count > 80 {
            return String(firstLine.prefix(77)) + "..."
        }
        return firstLine
    }
}
