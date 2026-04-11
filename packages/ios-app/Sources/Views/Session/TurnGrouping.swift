import Foundation

// MARK: - Turn Group Model

struct TurnGroup: Identifiable, Equatable {
    let turnNumber: Int
    let events: [SessionEvent]
    let analyticsData: ConsolidatedAnalytics.TurnData?
    let userMessagePreview: String?
    let isInherited: Bool

    /// Composite ID prevents collisions in forked sessions where inherited and
    /// current turns can share the same turn number.
    var id: String { "\(isInherited ? "i" : "c")\(turnNumber)" }

    static func == (lhs: TurnGroup, rhs: TurnGroup) -> Bool {
        lhs.turnNumber == rhs.turnNumber
            && lhs.events.map(\.id) == rhs.events.map(\.id)
            && lhs.isInherited == rhs.isInherited
    }
}

// MARK: - Turn Grouping Logic

enum TurnGrouping {

    /// Groups events into turns using boundary-based grouping.
    ///
    /// Most event types only carry a `turn` field on assistant messages, tool
    /// calls, and stream events — user messages, session lifecycle events, and
    /// worktree events do NOT. Grouping purely by payload `turn` field would
    /// dump all user messages and session events into turn 0.
    ///
    /// Instead, we walk events in sequence order and assign turn numbers using
    /// two passes:
    ///   1. Build a map from each event to the turn it belongs to, using the
    ///      `turn` field where present and propagating it to neighboring events.
    ///   2. Group events by their assigned turn numbers.
    ///
    /// The propagation rule: walk events in order. Track "current turn".
    /// - If an event has an explicit `turn` in payload → use it, update current.
    /// - If `message.user` → look ahead for the next event with a `turn` field
    ///   and use that turn number (the user message starts that turn).
    /// - Otherwise → use the current turn (events between turns inherit from
    ///   the last known turn).
    /// - Events before any turn is established go to turn 0 (session setup).
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
            let preview = extractUserMessagePreview(from: turnEvents)
            let isInherited = turnEvents.allSatisfy { $0.sessionId != currentSessionId }

            return TurnGroup(
                turnNumber: turn,
                events: turnEvents,
                analyticsData: analyticsMap[turn],
                userMessagePreview: preview,
                isInherited: isInherited
            )
        }
    }

    /// Assigns a turn number to each event in sequence order.
    ///
    /// Returns an array parallel to `events` with the assigned turn number.
    private static func assignTurnNumbers(_ events: [SessionEvent]) -> [Int] {
        var assignments = [Int](repeating: 0, count: events.count)
        var currentTurn = 0

        // First pass: find explicit turn numbers and build a forward-lookup
        // for user messages that precede their turn's assistant message.
        var explicitTurns: [Int: Int] = [:] // index → turn number
        for (i, event) in events.enumerated() {
            if let turn = extractPayloadTurn(event), turn > 0 {
                explicitTurns[i] = turn
            }
        }

        // Second pass: assign turn numbers
        for i in 0..<events.count {
            let event = events[i]

            if let turn = explicitTurns[i] {
                // Event has explicit turn
                currentTurn = turn
                assignments[i] = turn
            } else if event.eventType == .messageUser {
                // User message: look ahead for the next explicit turn
                let nextTurn = lookAheadForTurn(from: i + 1, events: events, explicitTurns: explicitTurns)
                if let next = nextTurn {
                    currentTurn = next
                    assignments[i] = next
                } else {
                    // No future turn found — use current + 1 as estimate
                    currentTurn += 1
                    assignments[i] = currentTurn
                }
            } else {
                // No explicit turn — inherit current
                assignments[i] = currentTurn
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
        for event in events {
            guard event.eventType == .messageUser else { continue }

            // Try to extract content from payload
            if let content = event.payload["content"]?.value as? String, !content.isEmpty {
                let firstLine = content.components(separatedBy: .newlines).first ?? content
                if firstLine.count > 80 {
                    return String(firstLine.prefix(77)) + "..."
                }
                return firstLine
            }

            // Try content array format (array of blocks)
            if let contentArray = event.payload["content"]?.value as? [[String: Any]] {
                for block in contentArray {
                    if let text = block["text"] as? String, !text.isEmpty {
                        let firstLine = text.components(separatedBy: .newlines).first ?? text
                        if firstLine.count > 80 {
                            return String(firstLine.prefix(77)) + "..."
                        }
                        return firstLine
                    }
                }
            }
        }
        return nil
    }
}
