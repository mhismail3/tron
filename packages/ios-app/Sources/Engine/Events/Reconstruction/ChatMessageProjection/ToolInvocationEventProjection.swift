import Foundation

/// Event projections for transforming tool invocation events into ChatMessages.
///
/// Projects: tool.invocation.started, tool.invocation.completed
///
/// Note: These projections are for standalone tool event transformation.
/// The interleaved content processor handles provider tool_invocation content blocks
/// within message.assistant events differently.
enum ToolInvocationEventProjection {

    /// Transform tool.invocation.started event into a ChatMessage.
    ///
    /// Started events represent the invocation of a tool by the agent.
    /// Returns nil since invocations are typically displayed via message.assistant
    /// content blocks, not as standalone messages.
    static func transformInvocationStarted(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ToolInvocationStartedPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .assistant,
            content: .toolInvocation(ToolInvocationData(
                id: parsed.invocationId,
                status: .running,
                arguments: parsed.arguments,
                identity: parsed.identity
            )),
            timestamp: timestamp,
            turnNumber: parsed.turn
        )
    }

    /// Transform tool.invocation.completed event into a ChatMessage.
    ///
    /// Completed events contain the output of a completed tool invocation.
    /// Returns nil since results are typically combined with started events
    /// during interleaved content processing.
    static func transformInvocationCompleted(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ToolInvocationCompletedPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .tool,
            content: .toolResult(ToolInvocationResultData(
                id: parsed.invocationId,
                content: parsed.content,
                isError: parsed.isError,
                identity: parsed.identity,
                arguments: nil,
                durationMs: parsed.durationMs,
                details: parsed.details
            )),
            timestamp: timestamp
        )
    }
}
