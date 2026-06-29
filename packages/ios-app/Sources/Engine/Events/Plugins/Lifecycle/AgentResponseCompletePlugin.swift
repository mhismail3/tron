import Foundation

/// Plugin for the server's response-complete lifecycle marker.
///
/// `agent.turn_end` remains the canonical UI metadata event; this marker is
/// parsed so live/reconstructed streams keep session and sequence ownership
/// instead of falling through as an unknown global event.
enum AgentResponseCompletePlugin: EventPlugin {
    static let eventType = "agent.response_complete"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        nil
    }
}
