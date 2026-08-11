import Foundation

/// Event projections for transforming message events into ChatMessages.
///
/// Projects: message.user, message.agent, and message.assistant
///
/// Note: The interleaved message.assistant transformation (preserving text/tool order)
/// is handled separately in InterleavedContentProcessor.
enum MessageEventProjection {

    /// Transform one durable inter-agent message without reclassifying it as
    /// user intent. Every coordination row stays distinct so sender, kind,
    /// authority, assignment, and reply provenance remain auditable.
    static func transformAgentMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date,
        eventId: String? = nil
    ) -> ChatMessage? {
        guard let parsed = AgentMessageContent(eventPayload: payload) else {
            return nil
        }
        return ChatMessage(
            role: .agent,
            content: .text(parsed.text),
            timestamp: timestamp,
            agentMessage: parsed,
            eventId: eventId
        )
    }

    /// Transform message.user event into a ChatMessage.
    ///
    /// User messages contain the user's input to the agent.
    static func transformUserMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = UserMessagePayload(from: payload) else { return nil }

        // Skip tool_result context messages - they're LLM conversation context,
        // not displayable user messages. Tool results are displayed via tool.invocation.completed events.
        if parsed.isToolResultContext {
            return nil
        }

        if parsed.userInputAnswer != nil {
            // The answer is folded into its originating request by the
            // reconstruction map. Rendering it again would create a redundant
            // second chat pill for the same durable interaction.
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
    /// Tool blocks are handled separately by tool.invocation.started/tool.invocation.completed events
    /// or by the interleaved content processor.
    static func transformAssistantMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = AssistantMessagePayload(from: payload) else {
            return nil
        }

        // CRITICAL: Only extract TEXT from assistant messages
        // Tool blocks are handled by tool.invocation.started/tool.invocation.completed events
        guard let text = parsed.textContent, !text.isEmpty else { return nil }

        var message = ChatMessage(
            role: .assistant,
            content: .text(text),
            timestamp: timestamp,
            turnNumber: parsed.turn,
            hasThinking: parsed.hasThinking,
            agentDeliveryProvenance: parsed.agentDeliveryProvenance,
            isFinalAssistantResponse: parsed.isFinalAssistantResponse
        )
        message.applyFinalAssistantResponseMetadata(
            tokenRecord: parsed.tokenRecord,
            model: parsed.model,
            latencyMs: parsed.latencyMs
        )
        return message
    }

}
