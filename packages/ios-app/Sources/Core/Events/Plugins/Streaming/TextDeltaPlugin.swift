import Foundation

/// Plugin for handling text delta streaming events.
/// These events deliver incremental text content from the agent's response.
enum TextDeltaPlugin: EventPlugin {
    static let eventType = "agent.text_delta"

    // MARK: - Event Data

    struct EventData: Decodable, Sendable {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let delta: String
            let messageIndex: Int?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let delta: String
        let messageIndex: Int?
    }

    // MARK: - Protocol Implementation

    static func sessionId(from event: EventData) -> String? {
        event.sessionId
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(delta: event.data.delta, messageIndex: event.data.messageIndex)
    }
}
