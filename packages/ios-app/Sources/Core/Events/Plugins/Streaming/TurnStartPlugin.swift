import Foundation

/// Plugin for handling turn start events.
/// These events signal the beginning of an agent turn.
enum TurnStartPlugin: EventPlugin {
    static let eventType = "agent.turn_start"

    // MARK: - Event Data

    struct EventData: Decodable, Sendable {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let turn: Int?
            let turnNumber: Int?

            /// Unified turn number accessor (handles both field names).
            var number: Int { turn ?? turnNumber ?? 1 }
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let turnNumber: Int
    }

    // MARK: - Protocol Implementation

    static func sessionId(from event: EventData) -> String? {
        event.sessionId
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(turnNumber: event.data?.number ?? 1)
    }
}
