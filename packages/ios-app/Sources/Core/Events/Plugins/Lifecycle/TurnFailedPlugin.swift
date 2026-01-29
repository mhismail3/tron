import Foundation

/// Plugin for handling turn failed events.
/// These events signal that a turn failed due to errors.
enum TurnFailedPlugin: EventPlugin {
    static let eventType = "agent.turn_failed"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let turn: Int?
            let error: String?
            let code: String?
            let category: String?
            let recoverable: Bool?
            let partialContent: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let turn: Int
        let error: String
        let code: String?
        let category: String?
        let recoverable: Bool
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            turn: event.data?.turn ?? 0,
            error: event.data?.error ?? "Unknown error",
            code: event.data?.code,
            category: event.data?.category,
            recoverable: event.data?.recoverable ?? false
        )
    }
}
