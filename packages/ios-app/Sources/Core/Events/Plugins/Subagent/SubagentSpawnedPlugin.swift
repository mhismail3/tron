import Foundation

/// Plugin for handling subagent spawned events.
/// These events signal that a new subagent was created.
enum SubagentSpawnedPlugin: EventPlugin {
    static let eventType = "agent.subagent_spawned"

    // MARK: - Event Data

    struct EventData: Decodable, Sendable {
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

    static func sessionId(from event: EventData) -> String? {
        event.sessionId
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            subagentSessionId: event.data.subagentSessionId,
            task: event.data.task,
            model: event.data.model,
            workingDirectory: event.data.workingDirectory,
            toolCallId: event.data.toolCallId
        )
    }
}
