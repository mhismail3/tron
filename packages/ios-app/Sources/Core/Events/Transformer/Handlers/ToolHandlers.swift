import Foundation

/// Handlers for transforming tool events into ChatMessages.
///
/// Handles: tool.call, tool.result
///
/// Note: These handlers are for standalone tool event transformation.
/// The interleaved content processor handles tool_use content blocks
/// within message.assistant events differently.
enum ToolHandlers {

    /// Transform tool.call event into a ChatMessage.
    ///
    /// Tool call events represent the invocation of a tool by the agent.
    /// Returns nil since tool calls are typically displayed via message.assistant
    /// content blocks, not as standalone messages.
    static func transformToolCall(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ToolCallPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: parsed.name,
                toolCallId: parsed.toolCallId,
                arguments: parsed.arguments,
                status: .running,
                result: nil,
                durationMs: nil
            )),
            timestamp: timestamp,
            turnNumber: parsed.turn
        )
    }

    /// Transform tool.result event into a ChatMessage.
    ///
    /// Tool result events contain the output of a completed tool execution.
    /// Returns nil since tool results are typically combined with tool calls
    /// during interleaved content processing.
    static func transformToolResult(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ToolResultPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .toolResult,
            content: .toolResult(ToolResultData(
                toolCallId: parsed.toolCallId,
                content: parsed.content,
                isError: parsed.isError,
                toolName: parsed.name,
                arguments: parsed.arguments,
                durationMs: parsed.durationMs
            )),
            timestamp: timestamp
        )
    }
}
