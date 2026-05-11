import Foundation

/// Handlers for transforming message events into ChatMessages.
///
/// Handles: message.user, message.assistant, message.system
///
/// Note: The interleaved message.assistant transformation (preserving text/tool order)
/// is handled separately in InterleavedContentProcessor.
enum MessageHandlers {

    /// Transform message.user event into a ChatMessage.
    ///
    /// User messages contain the user's input to the agent.
    /// Interactive-tool responses (answered questions and subagent results) are
    /// identified by the server-provided `messageKind` field and rendered
    /// as chips — iOS does not parse the message text content for these.
    static func transformUserMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = UserMessagePayload(from: payload) else { return nil }

        // Skip tool_result context messages - they're LLM conversation context,
        // not displayable user messages. Tool results are displayed via tool.result events.
        if parsed.isToolResultContext {
            return nil
        }

        // Server-provided structured chip rendering (see the tools domain
        // interactive enrichment modules). No text scanning needed — the
        // server tags these messages with `messageKind` on the live path
        // and back-fills historical events during reconstruction.
        switch parsed.messageKind {
        case "answered_questions":
            return ChatMessage(
                role: .user,
                content: .answeredQuestions(questionCount: max(1, parsed.answerCount ?? 1)),
                timestamp: timestamp
            )
        case "subagent_results_delivered":
            return ChatMessage(
                role: .user,
                content: .subagentResultsDelivered(subagentCount: max(1, parsed.subagentCount ?? 1)),
                timestamp: timestamp
            )
        default:
            break
        }

        // Skip empty user messages (unless they have attachments or skills)
        guard !parsed.content.isEmpty || parsed.attachments != nil || parsed.skills != nil else { return nil }

        return ChatMessage(
            role: .user,
            content: .text(parsed.content),
            timestamp: timestamp,
            attachments: parsed.attachments,
            skills: parsed.skills
        )
    }

    /// Transform message.assistant event into a ChatMessage.
    ///
    /// This handler extracts only TEXT content from assistant messages.
    /// Tool blocks are handled separately by tool.call/tool.result events
    /// or by the interleaved content processor.
    static func transformAssistantMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = AssistantMessagePayload(from: payload) else {
            return nil
        }

        // CRITICAL: Only extract TEXT from assistant messages
        // Tool blocks are handled by tool.call/tool.result events
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
