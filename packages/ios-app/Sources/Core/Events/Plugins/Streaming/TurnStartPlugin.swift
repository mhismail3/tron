import Foundation

/// Plugin for handling turn start events.
/// These events signal the beginning of an agent turn.
enum TurnStartPlugin: DispatchableEventPlugin {
    static let eventType = "agent.turn_start"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let turn: Int?
            let turnNumber: Int?
            let agentPhase: String?

            /// Unified turn number accessor (handles both field names).
            var number: Int? { turn ?? turnNumber }
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let turnNumber: Int
        let agentPhase: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data, let turnNumber = data.number else { return nil }
        return Result(
            turnNumber: turnNumber,
            agentPhase: data.agentPhase ?? "processing"
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleTurnStart(r)
    }
}
