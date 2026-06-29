import Foundation

/// Plugin for the server's agent-start marker.
///
/// Session processing state is handled by dedicated session events; this marker
/// is parsed so it remains session-owned instead of falling through as unknown
/// global event noise.
enum AgentStartPlugin: EventPlugin {
    static let eventType = "agent.start"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        nil
    }
}
