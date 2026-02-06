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
            let toolCallId: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let subagentSessionId: String
        let task: String
        let model: String?
        let workingDirectory: String?
        let toolCallId: String?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            subagentSessionId: event.data.subagentSessionId,
            task: event.data.task,
            model: event.data.model,
            workingDirectory: event.data.workingDirectory,
            toolCallId: event.data.toolCallId
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleSubagentSpawned(r)
    }
}
