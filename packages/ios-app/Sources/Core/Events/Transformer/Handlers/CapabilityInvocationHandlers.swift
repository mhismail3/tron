import Foundation

/// Handlers for transforming capability invocation events into ChatMessages.
///
/// Handles: capability.invocation.started, capability.invocation.completed
///
/// Note: These handlers are for standalone capability event transformation.
/// The interleaved content processor handles provider tool_use content blocks
/// within message.assistant events differently.
enum CapabilityInvocationHandlers {

    /// Transform capability.invocation.started event into a ChatMessage.
    ///
    /// Started events represent the invocation of a capability by the agent.
    /// Returns nil since invocations are typically displayed via message.assistant
    /// content blocks, not as standalone messages.
    static func transformInvocationStarted(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = CapabilityInvocationStartedPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .assistant,
            content: .capabilityInvocation(CapabilityInvocationData(
                id: parsed.invocationId,
                status: .running,
                arguments: parsed.arguments,
                identity: parsed.identity
            )),
            timestamp: timestamp,
            turnNumber: parsed.turn
        )
    }

    /// Transform capability.invocation.completed event into a ChatMessage.
    ///
    /// Completed events contain the output of a completed capability invocation.
    /// Returns nil since results are typically combined with started events
    /// during interleaved content processing.
    static func transformInvocationCompleted(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = CapabilityInvocationCompletedPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .capability,
            content: .capabilityResult(CapabilityInvocationResultData(
                id: parsed.invocationId,
                content: parsed.content,
                isError: parsed.isError,
                identity: parsed.identity,
                arguments: parsed.arguments,
                durationMs: parsed.durationMs,
                details: parsed.details
            )),
            timestamp: timestamp
        )
    }
}
