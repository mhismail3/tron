import Foundation

/// Plugin for handling text delta streaming events.
/// These events deliver incremental text content from the agent's response.
enum TextDeltaPlugin: DispatchableEventPlugin {
    static let eventType = "agent.text_delta"

    // MARK: - Event Data

    struct EventData: StandardEventData {
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

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(delta: event.data.delta, messageIndex: event.data.messageIndex)
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleTextDelta(r.delta)
    }
}
