import Foundation

/// Compact Agent Control card projection.
///
/// The sheet renders this local-first, then refreshes it from server session
/// metadata or full event sync. `unknown` is the only state that should render
/// placeholder text; cached zeroes are real values.
struct AgentControlSummary: Equatable {
    enum Freshness: Equatable {
        case unknown
        case cached
        case refreshing
        case fresh
    }

    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var totalTokens: Int
    var totalCost: Double
    var eventCount: Int
    var messageCount: Int
    var totalTurns: Int
    var totalCapabilityInvocations: Int
    var capabilityInvocationsKnown: Bool
    var totalErrors: Int
    var freshness: Freshness

    var isKnown: Bool { freshness != .unknown }

    static let unknown = AgentControlSummary(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheCreationTokens: 0,
        totalTokens: 0,
        totalCost: 0,
        eventCount: 0,
        messageCount: 0,
        totalTurns: 0,
        totalCapabilityInvocations: 0,
        capabilityInvocationsKnown: false,
        totalErrors: 0,
        freshness: .unknown
    )

    static func fromSession(_ session: CachedSession?, freshness: Freshness) -> AgentControlSummary {
        guard let session else { return .unknown }
        return AgentControlSummary(
            inputTokens: session.inputTokens,
            outputTokens: session.outputTokens,
            cacheReadTokens: session.cacheReadTokens,
            cacheCreationTokens: session.cacheCreationTokens,
            totalTokens: session.inputTokens + session.outputTokens + session.cacheReadTokens + session.cacheCreationTokens,
            totalCost: session.cost,
            eventCount: session.eventCount,
            messageCount: session.messageCount,
            totalTurns: session.turnCount,
            totalCapabilityInvocations: 0,
            capabilityInvocationsKnown: session.eventCount == 0,
            totalErrors: 0,
            freshness: freshness
        )
    }

    static func fromEvents(
        _ events: [SessionEvent],
        analytics: ConsolidatedAnalytics,
        turnGroups: [TurnGroup],
        fallbackSession session: CachedSession?,
        freshness: Freshness
    ) -> AgentControlSummary {
        let sessionSummary = fromSession(session, freshness: freshness)
        let analyticsTokens = analytics.turns.reduce(0) { $0 + $1.totalTokens }
        let hasEventAnalytics = !analytics.turns.isEmpty
        let eventDetailsComplete = session != nil
            ? events.count >= sessionSummary.eventCount
            : !events.isEmpty
        return AgentControlSummary(
            inputTokens: hasEventAnalytics ? analytics.totalInputTokens : sessionSummary.inputTokens,
            outputTokens: hasEventAnalytics ? analytics.totalOutputTokens : sessionSummary.outputTokens,
            cacheReadTokens: hasEventAnalytics ? analytics.totalCacheReadTokens : sessionSummary.cacheReadTokens,
            cacheCreationTokens: hasEventAnalytics ? analytics.totalCacheCreationTokens : sessionSummary.cacheCreationTokens,
            totalTokens: hasEventAnalytics ? analyticsTokens : sessionSummary.totalTokens,
            totalCost: hasEventAnalytics ? analytics.totalCost : sessionSummary.totalCost,
            eventCount: max(events.count, sessionSummary.eventCount),
            messageCount: max(sessionSummary.messageCount, events.filter {
                $0.type == PersistedEventType.messageUser.rawValue || $0.type == PersistedEventType.messageAssistant.rawValue
            }.count),
            totalTurns: max(turnGroups.count, sessionSummary.totalTurns),
            totalCapabilityInvocations: analytics.totalCapabilityInvocations,
            capabilityInvocationsKnown: eventDetailsComplete,
            totalErrors: analytics.totalErrors,
            freshness: freshness
        )
    }

    func withFreshness(_ freshness: Freshness) -> AgentControlSummary {
        var copy = self
        copy.freshness = freshness
        return copy
    }
}
