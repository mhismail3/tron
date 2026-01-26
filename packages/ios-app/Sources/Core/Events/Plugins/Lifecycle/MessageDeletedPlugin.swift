import Foundation

/// Plugin for handling message deleted events.
/// These events signal that a message was deleted from the conversation.
enum MessageDeletedPlugin: EventPlugin {
    static let eventType = "agent.message_deleted"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let targetEventId: String
            let targetType: String
            let targetTurn: Int?
            let reason: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let targetEventId: String
        let targetType: String
        let targetTurn: Int?
        let reason: String?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            targetEventId: event.data.targetEventId,
            targetType: event.data.targetType,
            targetTurn: event.data.targetTurn,
            reason: event.data.reason
        )
    }
}
