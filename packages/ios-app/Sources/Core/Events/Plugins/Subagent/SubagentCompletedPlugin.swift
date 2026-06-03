import Foundation

/// Plugin for handling subagent completion events.
/// These events signal that a subagent completed successfully.
enum SubagentCompletedPlugin: DispatchableEventPlugin {
    static let eventType = "agent.subagent_completed"

    // MARK: - Event Data

    struct EventData: StandardEventData {
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
            let model: String?
            let taskProfile: SubagentTaskProfilePresentation?
            let modelRouting: SubagentModelRoutingPresentation?
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
        let model: String?
        let taskProfile: SubagentTaskProfilePresentation?
        let modelRouting: SubagentModelRoutingPresentation?

        init(
            subagentSessionId: String,
            resultSummary: String,
            fullOutput: String?,
            totalTurns: Int,
            duration: Int,
            tokenUsage: TokenUsage?,
            model: String?,
            taskProfile: SubagentTaskProfilePresentation? = nil,
            modelRouting: SubagentModelRoutingPresentation? = nil
        ) {
            self.subagentSessionId = subagentSessionId
            self.resultSummary = resultSummary
            self.fullOutput = fullOutput
            self.totalTurns = totalTurns
            self.duration = duration
            self.tokenUsage = tokenUsage
            self.model = model
            self.taskProfile = taskProfile
            self.modelRouting = modelRouting
        }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            subagentSessionId: event.data.subagentSessionId,
            resultSummary: event.data.resultSummary,
            fullOutput: event.data.fullOutput,
            totalTurns: event.data.totalTurns,
            duration: event.data.duration,
            tokenUsage: event.data.tokenUsage,
            model: event.data.model,
            taskProfile: event.data.taskProfile,
            modelRouting: event.data.modelRouting
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleSubagentCompleted(r)
    }
}
