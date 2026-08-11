import Foundation

/// Coordination lifecycle events are invalidation hints. EngineClient
/// coalesces them and consumers reread canonical server projections; these
/// plugins keep the events session-scoped in the ordinary event stream.
struct AgentCoordinationProjectionEventData: StandardEventData {
    let type: String
    let sessionId: String?
    let timestamp: String?
}

enum AgentCoordinationLifecyclePlugin: EventPlugin {
    static let eventType = "agent.lifecycle"
    typealias EventData = AgentCoordinationProjectionEventData

    static func transform(_ event: EventData) -> (any EventResult)? { nil }
}

enum AgentAssignmentProjectionPlugin: EventPlugin {
    static let eventType = "agent.assignment"
    typealias EventData = AgentCoordinationProjectionEventData

    static func transform(_ event: EventData) -> (any EventResult)? { nil }
}

enum AgentMessageProjectionPlugin: EventPlugin {
    static let eventType = "agent.message"
    typealias EventData = AgentCoordinationProjectionEventData

    static func transform(_ event: EventData) -> (any EventResult)? { nil }
}
