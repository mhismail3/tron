import Foundation

/// Plugin for handling subagent completion events.
/// These events signal that a subagent completed successfully.
enum SubagentCompletedPlugin: EventPlugin {
    static let eventType = "agent.subagent_completed"

    // MARK: - Event Data

    struct EventData: Decodable, Sendable {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let subagentSessionId: String
            let resultSummary: String
            let fullOutput: String?
            let totalTurns: Int
            let duration: Int
            let tokenUsage: TokenUsage?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let subagentSessionId: String
        let resultSummary: String
        let fullOutput: String?
        let totalTurns: Int
        let duration: Int
        let tokenUsage: TokenUsage?
    }

    // MARK: - Protocol Implementation

    static func sessionId(from event: EventData) -> String? {
        event.sessionId
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            subagentSessionId: event.data.subagentSessionId,
            resultSummary: event.data.resultSummary,
            fullOutput: event.data.fullOutput,
            totalTurns: event.data.totalTurns,
            duration: event.data.duration,
            tokenUsage: event.data.tokenUsage
        )
    }
}
