import Foundation

/// Event projections for transforming message events into ChatMessages.
///
/// Projects: message.user, message.assistant, message.system
///
/// Note: The interleaved message.assistant transformation (preserving text/capability order)
/// is handled separately in InterleavedContentProcessor.
enum MessageEventProjection {

    /// Transform message.user event into a ChatMessage.
    ///
    /// User messages contain the user's input to the agent.
    static func transformUserMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = UserMessagePayload(from: payload) else { return nil }

        // Skip capability_result context messages - they're LLM conversation context,
        // not displayable user messages. Capability results are displayed via capability.invocation.completed events.
        if parsed.isCapabilityResultContext {
            return nil
        }

        // Skip empty user messages unless they have attachments.
        guard !parsed.content.isEmpty || parsed.attachments != nil else { return nil }

        return ChatMessage(
            role: .user,
            content: .text(parsed.content),
            timestamp: timestamp,
            attachments: parsed.attachments
        )
    }

    /// Transform message.assistant event into a ChatMessage.
    ///
    /// This projection extracts only TEXT content from assistant messages.
    /// Capability blocks are handled separately by capability.invocation.started/capability.invocation.completed events
    /// or by the interleaved content processor.
    static func transformAssistantMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = AssistantMessagePayload(from: payload) else {
            return nil
        }

        // CRITICAL: Only extract TEXT from assistant messages
        // Capability blocks are handled by capability.invocation.started/capability.invocation.completed events
        guard let text = parsed.textContent, !text.isEmpty else { return nil }

        return ChatMessage(
            role: .assistant,
            content: .text(text),
            timestamp: timestamp,
            tokenRecord: parsed.tokenRecord,
            model: parsed.model,
            latencyMs: parsed.latencyMs,
            turnNumber: parsed.turn,
            hasThinking: parsed.hasThinking,
            stopReason: parsed.stopReason?.rawValue
        )
    }

    /// Transform message.system event into a ChatMessage.
    ///
    /// System messages are typically internal context setup and are not displayed.
    static func transformSystemMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = SystemMessagePayload(from: payload) else { return nil }

        return ChatMessage(
            role: .system,
            content: .text(parsed.content),
            timestamp: timestamp
        )
    }
}
