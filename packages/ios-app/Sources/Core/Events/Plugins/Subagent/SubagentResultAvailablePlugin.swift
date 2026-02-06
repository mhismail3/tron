import Foundation

/// Plugin for handling subagent result available notification events.
/// These events are emitted when a non-blocking subagent completes while the parent is idle,
/// allowing the user to review and send results to the agent.
enum SubagentResultAvailablePlugin: DispatchableEventPlugin {
    static let eventType = "agent.subagent_result_available"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let parentSessionId: String
            let subagentSessionId: String
            let task: String
            let resultSummary: String
            let success: Bool
            let totalTurns: Int
            let duration: Int
            let tokenUsage: TokenUsage?
            let error: String?
            let completedAt: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let parentSessionId: String
        let subagentSessionId: String
        let task: String
        let resultSummary: String
        let success: Bool
        let totalTurns: Int
        let duration: Int
        let tokenUsage: TokenUsage?
        let error: String?
        let completedAt: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            parentSessionId: event.data.parentSessionId,
            subagentSessionId: event.data.subagentSessionId,
            task: event.data.task,
            resultSummary: event.data.resultSummary,
            success: event.data.success,
            totalTurns: event.data.totalTurns,
            duration: event.data.duration,
            tokenUsage: event.data.tokenUsage,
            error: event.data.error,
            completedAt: event.data.completedAt
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleSubagentResultAvailable(r)
    }
}
