import Foundation

/// Plugin for handling thinking delta streaming events.
/// These events deliver incremental thinking/reasoning content.
enum ThinkingDeltaPlugin: EventPlugin {
    static let eventType = "agent.thinking_delta"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let delta: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let delta: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(delta: event.data.delta)
    }
}
