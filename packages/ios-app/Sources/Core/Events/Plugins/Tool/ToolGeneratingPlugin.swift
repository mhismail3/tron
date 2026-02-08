import Foundation

/// Plugin for handling tool generating events.
/// These events signal that the LLM has started generating a tool call,
/// BEFORE arguments are fully streamed. This allows the UI to show a
/// spinning chip immediately instead of waiting for tool execution.
enum ToolGeneratingPlugin: DispatchableEventPlugin {
    static let eventType = "agent.tool_generating"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let toolName: String
            let toolCallId: String
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let toolName: String
        let toolCallId: String
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            toolName: event.data.toolName,
            toolCallId: event.data.toolCallId
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleToolGenerating(r)
    }
}
