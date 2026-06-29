import Foundation

/// Plugin for the server's thinking-end marker.
///
/// The UI receives visible thinking content through `agent.thinking_delta`.
/// The end marker may carry provider-private thinking text on the wire, so this
/// plugin intentionally parses only standard routing fields and returns no UI
/// result.
enum ThinkingEndPlugin: EventPlugin {
    static let eventType = "agent.thinking_end"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        nil
    }
}
