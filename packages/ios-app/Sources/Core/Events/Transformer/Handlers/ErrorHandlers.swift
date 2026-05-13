import Foundation

/// Handlers for transforming error events into ChatMessages.
///
/// Handles: error.agent, error.capability, error.provider
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

    /// Transform error.capability event into a ChatMessage.
    ///
    /// Capability errors represent failures during capability execution.
    /// Includes model tool name, error message, and optional error code.
    static func transformCapabilityError(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = CapabilityErrorPayload(from: payload) else { return nil }

        var errorText = "Capability '\(parsed.modelToolName)' failed: \(parsed.error)"
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
    /// All provider errors render as interactive notification pills. The
    /// payload's `category` is required — when the originating layer couldn't
    /// classify, it emits `"unknown"` literally. `ErrorCategoryDisplay` maps
    /// `"unknown"` to a generic-icon pill, so every category (including
    /// `"unknown"`) takes the same rendering path.
    static func transformProviderError(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ProviderErrorPayload(from: payload) else { return nil }

        let data = ProviderErrorDetailData(
            provider: parsed.provider,
            category: parsed.category,
            message: parsed.error,
            suggestion: parsed.suggestion,
            retryable: parsed.retryable,
            statusCode: parsed.statusCode,
            errorType: parsed.errorType,
            model: parsed.model
        )
        return ChatMessage(
            role: .system,
            content: .providerError(data),
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
