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
            /// Server-provided routing hint: true if iOS should surface a
            /// notification, false if the parent agent is actively running
            /// (backend delivers results via system-prompt injection).
            /// Defaults to `true` for backward compatibility with historical
            /// events that predate this field.
            let notify: Bool

            private enum CodingKeys: String, CodingKey {
                case parentSessionId, subagentSessionId, task, resultSummary,
                     success, totalTurns, duration, tokenUsage, error, completedAt, notify
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                parentSessionId = try c.decode(String.self, forKey: .parentSessionId)
                subagentSessionId = try c.decode(String.self, forKey: .subagentSessionId)
                task = try c.decode(String.self, forKey: .task)
                resultSummary = try c.decode(String.self, forKey: .resultSummary)
                success = try c.decode(Bool.self, forKey: .success)
                totalTurns = try c.decode(Int.self, forKey: .totalTurns)
                duration = try c.decode(Int.self, forKey: .duration)
                tokenUsage = try c.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage)
                error = try c.decodeIfPresent(String.self, forKey: .error)
                completedAt = try c.decode(String.self, forKey: .completedAt)
                notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
            }
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
        let notify: Bool
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
            completedAt: event.data.completedAt,
            notify: event.data.notify
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleSubagentResultAvailable(r)
    }
}
