import Foundation

/// Plugin for handling agent ready events.
/// Emitted after background hooks (compaction, memory) complete.
/// Signals that the agent is ready to accept new input.
enum AgentReadyPlugin: DispatchableEventPlugin {
    static let eventType = "agent.ready"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    // MARK: - Result

    struct Result: EventResult {}

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result()
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        context.handleAgentReady()
    }
}
