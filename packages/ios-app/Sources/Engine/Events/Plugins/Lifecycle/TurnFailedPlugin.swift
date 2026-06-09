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
            let retryable: Bool?
            let recoverable: Bool?
            let origin: String?
            let details: [String: AnyCodable]?
            let partialContent: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let turn: Int
        let error: String
        let code: String?
        let category: String?
        let retryable: Bool?
        let recoverable: Bool
        let origin: String?
        let details: [String: AnyCodable]?
        let failure: CanonicalFailurePayload?
        let partialContent: String?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        guard let turn = data.turn,
              let failure = CanonicalFailurePayload.fromDetails(data.details) else {
            return nil
        }

        return Result(
            turn: turn,
            error: failure.message,
            code: failure.code,
            category: failure.category,
            retryable: failure.retryable,
            recoverable: failure.recoverable,
            origin: failure.origin,
            details: data.details,
            failure: failure,
            partialContent: data.partialContent
        )
    }
}
