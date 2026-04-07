import Foundation

/// Plugin for `queued_message_sent` events.
/// Fired by the server when an auto-drained queued message is sent as a user prompt.
/// iOS renders a user message bubble so the chat shows the queued text in real-time.
enum QueuedMessageSentPlugin: DispatchableEventPlugin {
    static let eventType = "agent.queued_message_sent"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let text: String
            let queueId: String
        }
    }

    struct Result: EventResult {
        let text: String
        let queueId: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            text: event.data.text,
            queueId: event.data.queueId
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleQueuedMessageSent(r)
    }
}
