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
            let taskProfile: SubagentTaskProfilePresentation?
            let modelRouting: SubagentModelRoutingPresentation?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let subagentSessionId: String
        let error: String
        let duration: Int
        let taskProfile: SubagentTaskProfilePresentation?
        let modelRouting: SubagentModelRoutingPresentation?

        init(
            subagentSessionId: String,
            error: String,
            duration: Int,
            taskProfile: SubagentTaskProfilePresentation? = nil,
            modelRouting: SubagentModelRoutingPresentation? = nil
        ) {
            self.subagentSessionId = subagentSessionId
            self.error = error
            self.duration = duration
            self.taskProfile = taskProfile
            self.modelRouting = modelRouting
        }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            subagentSessionId: event.data.subagentSessionId,
            error: event.data.error,
            duration: event.data.duration,
            taskProfile: event.data.taskProfile,
            modelRouting: event.data.modelRouting
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleSubagentFailed(r)
    }
}
