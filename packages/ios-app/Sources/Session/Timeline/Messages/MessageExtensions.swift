import Foundation

// MARK: - Message Extensions

extension ChatMessage {
    /// Extract the transport invocationId/capability invocation id from this message.
    var invocationId: String? {
        switch content {
        case .capabilityInvocation(let data):
            return data.id
        case .capabilityResult(let data):
            return data.id
        default:
            return nil
        }
    }

    /// Create a user message with optional attachments.
    static func user(_ text: String, attachments: [Attachment]? = nil) -> ChatMessage {
        ChatMessage(role: .user, content: .text(text), attachments: attachments)
    }

    static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .text(text))
    }

    static func streaming(_ text: String = "") -> ChatMessage {
        ChatMessage(role: .assistant, content: .streaming(text), isStreaming: true)
    }

    /// Create a streaming message that reuses a specific UUID. Used
    /// only on the reconstruction path to preserve bubble identity
    /// across a transient disconnect so the UI doesn't flicker the
    /// streaming message away and back.
    static func streamingReusing(id: UUID, text: String = "") -> ChatMessage {
        ChatMessage(id: id, role: .assistant, content: .streaming(text), isStreaming: true)
    }

    static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, content: .text(text))
    }

    static func error(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .error(text))
    }

    static func localNotification(_ notification: LocalChatNotification) -> ChatMessage {
        ChatMessage(id: notification.id, role: .system, content: .localNotification(notification))
    }

    /// In-chat notification for model changes
    static func modelChange(from: String, to: String) -> ChatMessage {
        ChatMessage(role: .system, content: .modelChange(from: from, to: to))
    }

    /// In-chat notification for reasoning level changes
    static func reasoningLevelChange(from: String, to: String) -> ChatMessage {
        ChatMessage(role: .system, content: .reasoningLevelChange(from: from, to: to))
    }

    /// In-chat notification for session interruption
    static func interrupted() -> ChatMessage {
        ChatMessage(role: .system, content: .interrupted)
    }

    /// In-chat notification for compaction in progress (spinning indicator)
    static func compactionInProgress(reason: String) -> ChatMessage {
        ChatMessage(role: .system, content: .compactionInProgress(reason: reason))
    }

    /// In-chat notification for context compaction
    static func compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String? = nil, preservedTurns: Int? = nil, summarizedTurns: Int? = nil) -> ChatMessage {
        ChatMessage(role: .system, content: .compaction(tokensBefore: tokensBefore, tokensAfter: tokensAfter, reason: reason, summary: summary, preservedTurns: preservedTurns, summarizedTurns: summarizedTurns))
    }

    /// In-chat notification for context clearing
    static func contextCleared(tokensBefore: Int, tokensAfter: Int) -> ChatMessage {
        ChatMessage(role: .system, content: .contextCleared(tokensBefore: tokensBefore, tokensAfter: tokensAfter))
    }

    /// In-chat notification for message deletion from context
    static func messageDeleted(targetType: String) -> ChatMessage {
        ChatMessage(role: .system, content: .messageDeleted(targetType: targetType))
    }

    /// In-chat notification for catching up to in-progress session
    static func catchingUp() -> ChatMessage {
        ChatMessage(role: .system, content: .catchingUp)
    }

    /// Thinking block message (appears before the text response)
    static func thinking(_ text: String, isExpanded: Bool = false, isStreaming: Bool = false) -> ChatMessage {
        ChatMessage(role: .assistant, content: .thinking(visible: text, isExpanded: isExpanded, isStreaming: isStreaming))
    }

    /// In-chat notification for provider API errors
    static func providerError(_ data: ProviderErrorDetailData) -> ChatMessage {
        ChatMessage(role: .system, content: .providerError(data))
    }
}
