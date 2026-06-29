import Foundation

/// Plugin for the server's thinking-start marker.
///
/// Visible thinking content is handled by `agent.thinking_delta`; this marker is
/// parsed only for session/sequence ownership.
enum ThinkingStartPlugin: EventPlugin {
    static let eventType = "agent.thinking_start"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        nil
    }
}
