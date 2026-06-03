import Foundation

/// Plugin for handling subagent spawned events.
/// These events signal that a new subagent was created.
enum SubagentSpawnedPlugin: DispatchableEventPlugin {
    static let eventType = "agent.subagent_spawned"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let subagentSessionId: String
            let task: String
            let model: String?
            let workingDirectory: String?
            let invocationId: String?
            let blocking: Bool?
            let spawnType: String?
            let taskProfile: SubagentTaskProfilePresentation?
            let modelRouting: SubagentModelRoutingPresentation?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let subagentSessionId: String
        let task: String
        let model: String?
        let workingDirectory: String?
        let invocationId: String?
        let blocking: Bool
        let spawnType: String?
        let taskProfile: SubagentTaskProfilePresentation?
        let modelRouting: SubagentModelRoutingPresentation?

        init(
            subagentSessionId: String,
            task: String,
            model: String?,
            workingDirectory: String?,
            invocationId: String?,
            blocking: Bool,
            spawnType: String?,
            taskProfile: SubagentTaskProfilePresentation? = nil,
            modelRouting: SubagentModelRoutingPresentation? = nil
        ) {
            self.subagentSessionId = subagentSessionId
            self.task = task
            self.model = model
            self.workingDirectory = workingDirectory
            self.invocationId = invocationId
            self.blocking = blocking
            self.spawnType = spawnType
            self.taskProfile = taskProfile
            self.modelRouting = modelRouting
        }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            subagentSessionId: event.data.subagentSessionId,
            task: event.data.task,
            model: event.data.model,
            workingDirectory: event.data.workingDirectory,
            invocationId: event.data.invocationId,
            blocking: event.data.blocking ?? false,
            spawnType: event.data.spawnType,
            taskProfile: event.data.taskProfile,
            modelRouting: event.data.modelRouting
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleSubagentSpawned(r)
    }
}
