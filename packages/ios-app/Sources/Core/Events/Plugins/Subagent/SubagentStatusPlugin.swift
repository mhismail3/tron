import Foundation

/// Plugin for handling subagent status update events.
/// These events signal status changes in a running subagent.
enum SubagentStatusPlugin: DispatchableEventPlugin {
    static let eventType = "agent.subagent_status"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let subagentSessionId: String
            let status: String
            let currentTurn: Int
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let subagentSessionId: String
        let status: String
        let currentTurn: Int
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            subagentSessionId: event.data.subagentSessionId,
            status: event.data.status,
            currentTurn: event.data.currentTurn
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleSubagentStatus(r)
    }
}
