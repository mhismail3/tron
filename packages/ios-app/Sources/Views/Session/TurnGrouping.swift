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

    /// Groups events into turns, matches with analytics data.
    ///
    /// Events are grouped by the `turn` field in their payload.
    /// Events without a turn number are grouped into turn 0 ("Session" events).
    /// Results are sorted by turn number ascending.
    static func group(
        events: [SessionEvent],
        analytics: ConsolidatedAnalytics,
        currentSessionId: String
    ) -> [TurnGroup] {
        guard !events.isEmpty else { return [] }

        // Group events by turn number
        var turnMap: [Int: [SessionEvent]] = [:]
        for event in events {
            let turn = turnNumber(for: event)
            turnMap[turn, default: []].append(event)
        }

        // Build analytics lookup by turn number
        let analyticsMap: [Int: ConsolidatedAnalytics.TurnData] = Dictionary(
            uniqueKeysWithValues: analytics.turns.map { ($0.turn, $0) }
        )

        // Build TurnGroups sorted by turn number
        return turnMap.keys.sorted().map { turn in
            let turnEvents = turnMap[turn]!
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

    /// Extracts turn number from event payload, defaulting to 0.
    static func turnNumber(for event: SessionEvent) -> Int {
        if let turn = event.payload["turn"]?.value as? Int {
            return turn
        }
        if let turn = event.payload["turn"]?.value as? Double {
            return Int(turn)
        }
        return 0
    }
}
