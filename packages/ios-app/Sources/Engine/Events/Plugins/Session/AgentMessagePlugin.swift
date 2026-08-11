import Foundation

/// Live projection of the same typed content persisted as `message.agent`.
/// The server publishes this only after the durable event exists, and carries
/// its event identity so live and reconstructed audit rows converge.
enum AgentMessagePlugin: DispatchableEventPlugin {
    static let eventType = "message.agent"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let eventId: String?
            let content: AgentMessageContent
        }
    }

    struct Result: EventResult, Equatable {
        let eventId: String?
        let content: AgentMessageContent
        let timestamp: Date

        var message: ChatMessage {
            ChatMessage(
                role: .agent,
                content: .text(content.text),
                timestamp: timestamp,
                agentMessage: content,
                eventId: eventId
            )
        }
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            eventId: event.data.eventId,
            content: event.data.content,
            timestamp: event.timestamp.map(EventSorter.parseTimestamp) ?? Date()
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let result = result as? Result else { return }
        context.handleAgentMessage(result)
    }
}

