import Foundation

/// Handles `session.processing_changed` events — global broadcasts for dashboard processing state.
/// Emitted by the server alongside AgentStart/AgentEnd so all clients learn about
/// any session's processing state instantly, eliminating the need for polling.
enum SessionProcessingChangedPlugin: EventPlugin {
    static let eventType = "session.processing_changed"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let isProcessing: Bool
        }
    }

    struct Result: EventResult {
        let isProcessing: Bool
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let isProcessing = event.data?.isProcessing else { return nil }
        return Result(isProcessing: isProcessing)
    }
}
