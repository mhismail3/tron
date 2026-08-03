import Foundation

/// Plugin for handling turn failed events.
/// These events signal that a turn failed due to errors.
enum TurnFailedPlugin: DispatchableEventPlugin {
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

        var isCancellation: Bool {
            CanonicalFailurePayload.isTurnCancellation(code: code)
        }
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

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let result = result as? Result else { return }
        context.handleTurnFailed(result)
    }
}
