import Foundation

// MARK: - Processed Event Item

/// Represents either a single event or a merged tool call+result pair for turn event display.
struct ProcessedEventItem: Identifiable {
    enum Kind {
        case single(SessionEvent)
        case mergedTool(call: SessionEvent, result: SessionEvent?)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .single(let event): return event.id
        case .mergedTool(let call, _): return "tool-\(call.id)"
        }
    }
}

// MARK: - Event Processing

/// Splits a turn's events into main content and post-turn lifecycle events,
/// merging tool call/result pairs into single items.
func processEventsForTurn(_ turn: TurnGroup) -> (main: [ProcessedEventItem], postTurn: [ProcessedEventItem]) {
    let events = turn.events
    let lastAssistantIndex = events.lastIndex(where: { $0.eventType == .messageAssistant })

    let lastMainIndex: Int
    if let lai = lastAssistantIndex {
        let afterAssistant = events[lai...]
        if let lastToolResult = afterAssistant.lastIndex(where: { $0.eventType == .toolResult }) {
            lastMainIndex = lastToolResult
        } else {
            lastMainIndex = lai
        }
    } else {
        lastMainIndex = events.count - 1
    }

    let mainEvents = lastMainIndex < events.count ? Array(events[...lastMainIndex]) : events
    let postTurnEvents = lastMainIndex + 1 < events.count ? Array(events[(lastMainIndex + 1)...]) : []

    let postTurnTypes: Set<SessionEventType> = [
        .configModelSwitch, .configPromptUpdate, .configReasoningLevel,
        .llmHookResult, .worktreeAcquired, .worktreeCommit, .worktreeReleased,
        .worktreeMerged, .worktreeRenamed, .skillActivated, .skillDeactivated,
        .memoryRetained, .rulesLoaded, .rulesActivated
    ]

    let filteredPostTurn = postTurnEvents.filter { postTurnTypes.contains($0.eventType) }

    var mainItems: [ProcessedEventItem] = []
    var resultByCallId: [String: SessionEvent] = [:]
    for event in mainEvents where event.eventType == .toolResult {
        if let callId = event.payload.string("toolCallId") {
            resultByCallId[callId] = event
        }
    }

    for event in mainEvents {
        if event.eventType == .toolResult { continue }
        if event.eventType == .toolCall {
            let callId = event.payload.string("toolCallId") ?? event.id
            let result = resultByCallId[callId]
            mainItems.append(ProcessedEventItem(kind: .mergedTool(call: event, result: result)))
        } else {
            mainItems.append(ProcessedEventItem(kind: .single(event)))
        }
    }

    let postTurnItems = filteredPostTurn.map { ProcessedEventItem(kind: .single($0)) }
    return (mainItems, postTurnItems)
}
