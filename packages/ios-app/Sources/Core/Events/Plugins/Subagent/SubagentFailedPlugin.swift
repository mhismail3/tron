import Foundation

/// Plugin for handling subagent failure events.
/// These events signal that a subagent failed.
enum SubagentFailedPlugin: DispatchableEventPlugin {
    static let eventType = "agent.subagent_failed"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let subagentSessionId: String
            let error: String
            let duration: Int
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let subagentSessionId: String
        let error: String
        let duration: Int
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            subagentSessionId: event.data.subagentSessionId,
            error: event.data.error,
            duration: event.data.duration
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleSubagentFailed(r)
    }
}
