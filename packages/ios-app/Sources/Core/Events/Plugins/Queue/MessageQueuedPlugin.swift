import Foundation

/// Plugin for `message.queued` events.
/// Adds a pending queue item to MessageQueueState (renders as pill above input bar).
enum MessageQueuedPlugin: DispatchableEventPlugin {
    static let eventType = "agent.message_queued"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let queueId: String
            let text: String
            let position: UInt32
        }
    }

    struct Result: EventResult {
        let queueId: String
        let text: String
        let position: UInt32
        let timestamp: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            queueId: event.data.queueId,
            text: event.data.text,
            position: event.data.position,
            timestamp: event.timestamp ?? ""
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleMessageQueued(r)
    }
}
