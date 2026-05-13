import Foundation

// MARK: - Processed Event Item

/// Represents either a single event or a merged capability invocation+result pair for turn event display.
struct ProcessedEventItem: Identifiable {
    enum Kind {
        case single(SessionEvent)
        case mergedCapability(call: SessionEvent, result: SessionEvent?)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .single(let event): return event.id
        case .mergedCapability(let call, _): return "capability-\(call.id)"
        }
    }
}

// MARK: - Event Processing

/// Event types considered post-turn lifecycle events (config changes, worktree ops, etc.)
private let postTurnEventTypes: Set<SessionEventType> = [
    .configModelSwitch, .configPromptUpdate, .configReasoningLevel,
    .llmHookResult, .worktreeAcquired, .worktreeCommit, .worktreeReleased,
    .worktreeMerged, .worktreeRenamed, .skillActivated, .skillDeactivated,
    .memoryRetained, .rulesLoaded, .rulesActivated
]

/// Splits a turn's events into main content and post-turn lifecycle events,
/// merging capability invocation/result pairs into single items.
func processEventsForTurn(_ turn: TurnGroup) -> (main: [ProcessedEventItem], postTurn: [ProcessedEventItem]) {
    let events = turn.events
    let lastAssistantIndex = events.lastIndex(where: { $0.eventType == .messageAssistant })

    let lastMainIndex: Int
    if let lai = lastAssistantIndex {
        let afterAssistant = events[lai...]
        if let lastCapabilityResult = afterAssistant.lastIndex(where: { $0.eventType == .capabilityInvocationCompleted }) {
            lastMainIndex = lastCapabilityResult
        } else {
            lastMainIndex = lai
        }
    } else {
        lastMainIndex = events.count - 1
    }

    let mainEvents = lastMainIndex < events.count ? Array(events[...lastMainIndex]) : events
    let postTurnEvents = lastMainIndex + 1 < events.count ? Array(events[(lastMainIndex + 1)...]) : []

    let filteredPostTurn = postTurnEvents.filter { postTurnEventTypes.contains($0.eventType) }

    var mainItems: [ProcessedEventItem] = []
    var resultByCallId: [String: SessionEvent] = [:]
    for event in mainEvents where event.eventType == .capabilityInvocationCompleted {
        if let callId = event.payload.string("invocationId") {
            resultByCallId[callId] = event
        }
    }

    for event in mainEvents {
        if event.eventType == .capabilityInvocationCompleted { continue }
        if event.eventType == .capabilityInvocationStarted {
            let callId = event.payload.string("invocationId") ?? event.id
            let result = resultByCallId[callId]
            mainItems.append(ProcessedEventItem(kind: .mergedCapability(call: event, result: result)))
        } else {
            mainItems.append(ProcessedEventItem(kind: .single(event)))
        }
    }

    let postTurnItems = filteredPostTurn.map { ProcessedEventItem(kind: .single($0)) }
    return (mainItems, postTurnItems)
}
