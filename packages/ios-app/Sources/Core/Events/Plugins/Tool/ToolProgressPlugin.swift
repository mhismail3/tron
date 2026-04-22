import Foundation

/// Plugin for handling long-running tool progress heartbeats.
/// Delivers optional status messages + completion fractions for tools like
/// Bash (stdout tail), WebFetch (bytes downloaded), and SpawnSubagent
/// (child turn count).
enum ToolProgressPlugin: DispatchableEventPlugin {
    static let eventType = "agent.tool_progress"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let toolCallId: String
            let message: String?
            let percent: Double?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let toolCallId: String
        let message: String?
        let percent: Double?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            toolCallId: event.data.toolCallId,
            message: event.data.message,
            percent: event.data.percent
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleToolProgress(r)
    }
}
