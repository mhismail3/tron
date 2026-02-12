import Foundation

/// Handlers for transforming error events into ChatMessages.
///
/// Handles: error.agent, error.tool, error.provider
enum ErrorHandlers {

    /// Transform error.agent event into a ChatMessage.
    ///
    /// Agent errors represent failures in the agent's processing logic.
    /// Shows error code and message if available.
    static func transformAgentError(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = AgentErrorPayload(from: payload) else { return nil }

        var errorText = parsed.error
        if let code = parsed.code {
            errorText = "[\(code)] \(errorText)"
        }

        return ChatMessage(
            role: .assistant,
            content: .error(errorText),
            timestamp: timestamp
        )
    }

    /// Transform error.tool event into a ChatMessage.
    ///
    /// Tool errors represent failures during tool execution.
    /// Includes tool name, error message, and optional error code.
    static func transformToolError(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ToolErrorPayload(from: payload) else { return nil }

        var errorText = "Tool '\(parsed.toolName)' failed: \(parsed.error)"
        if let code = parsed.code {
            errorText = "[\(code)] \(errorText)"
        }

        return ChatMessage(
            role: .assistant,
            content: .error(errorText),
            timestamp: timestamp
        )
    }

    /// Transform error.provider event into a ChatMessage.
    ///
    /// Provider errors with a category are rendered as interactive notification pills.
    /// Legacy events (no category) fall back to plain error text.
    static func transformProviderError(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ProviderErrorPayload(from: payload) else { return nil }

        // Enriched: render as provider error pill
        if let category = parsed.category, category != "unknown" {
            return ChatMessage(
                role: .system,
                content: .providerError(
                    provider: parsed.provider,
                    category: category,
                    message: parsed.error,
                    suggestion: parsed.suggestion,
                    retryable: parsed.retryable
                ),
                timestamp: timestamp
            )
        }

        // Legacy fallback: plain error text
        var errorText = "\(parsed.provider) error: \(parsed.error)"
        if let code = parsed.code {
            errorText = "[\(code)] \(errorText)"
        }
        if parsed.retryable, let retryAfter = parsed.retryAfter {
            errorText += " (retrying in \(retryAfter)ms)"
        }

        return ChatMessage(
            role: .assistant,
            content: .error(errorText),
            timestamp: timestamp
        )
    }

    /// Transform turn.failed event into a ChatMessage.
    ///
    /// Turn failed events represent errors that caused a turn to fail.
    /// Displayed as a system notification (red pill) in the chat.
    static func transformTurnFailed(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = TurnFailedPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .system,
            content: .systemEvent(.turnFailed(
                error: parsed.error,
                code: parsed.code,
                recoverable: parsed.recoverable
            )),
            timestamp: timestamp
        )
    }
}
