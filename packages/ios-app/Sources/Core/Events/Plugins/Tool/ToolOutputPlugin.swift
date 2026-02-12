import Foundation

/// Plugin for handling streaming tool output events.
/// These events deliver incremental stdout/stderr chunks while a tool is running.
enum ToolOutputPlugin: DispatchableEventPlugin {
    static let eventType = "agent.tool_output"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let toolCallId: String
            let output: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let toolCallId: String
        let output: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            toolCallId: event.data.toolCallId,
            output: event.data.output
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleToolOutput(r)
    }
}
