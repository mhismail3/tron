import Foundation

/// Plugin for `message.dequeued` events.
/// Removes a pending queue item from MessageQueueState (pill disappears).
enum MessageDequeuedPlugin: DispatchableEventPlugin {
    static let eventType = "agent.message_dequeued"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let queueId: String
            let reason: String
        }
    }

    struct Result: EventResult {
        let queueId: String
        let reason: String
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            queueId: event.data.queueId,
            reason: event.data.reason
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleMessageDequeued(r)
    }
}
