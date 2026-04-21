import Foundation

// MARK: - Message Extensions

extension ChatMessage {
    /// Extract the toolCallId from this message if it contains a tool (toolUse or toolResult).
    /// Returns nil for non-tool messages.
    var toolCallId: String? {
        switch content {
        case .toolUse(let data):
            return data.toolCallId
        case .toolResult(let data):
            return data.toolCallId
        case .askUserQuestion(let data):
            return data.toolCallId
        case .getConfirmation(let data):
            return data.toolCallId
        default:
            return nil
        }
    }

    /// Create a user message with optional attachments and skills
    static func user(_ text: String, attachments: [Attachment]? = nil, skills: [Skill]? = nil) -> ChatMessage {
        ChatMessage(role: .user, content: .text(text), attachments: attachments, skills: skills)
    }

    static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .text(text))
    }

    static func streaming(_ text: String = "") -> ChatMessage {
        ChatMessage(role: .assistant, content: .streaming(text), isStreaming: true)
    }

    /// H7: create a streaming message that reuses a specific UUID.
    /// Used only on the reconstruction path to preserve bubble
    /// identity across a transient disconnect so the UI doesn't
    /// flicker the streaming message away and back.
    static func streamingReusing(id: UUID, text: String = "") -> ChatMessage {
        ChatMessage(id: id, role: .assistant, content: .streaming(text), isStreaming: true)
    }

    static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, content: .text(text))
    }

    static func error(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .error(text))
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

    /// In-chat notification for transcription failure
    static func transcriptionFailed() -> ChatMessage {
        ChatMessage(role: .system, content: .transcriptionFailed)
    }

    /// In-chat notification for no speech detected
    static func transcriptionNoSpeech() -> ChatMessage {
        ChatMessage(role: .system, content: .transcriptionNoSpeech)
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

    /// In-chat notification for skill deactivation from context
    static func skillDeactivated(skillName: String) -> ChatMessage {
        ChatMessage(role: .system, content: .skillDeactivated(skillName: skillName))
    }

    /// In-chat notification for memory retain in progress (spinning indicator)
    static func memoryRetainInProgress() -> ChatMessage {
        ChatMessage(role: .system, content: .memoryRetainInProgress)
    }

    /// In-chat notification for automatic memory retain in progress (distinct label)
    static func memoryAutoRetainInProgress(intervalFired: Int) -> ChatMessage {
        ChatMessage(role: .system, content: .memoryAutoRetainInProgress(intervalFired: intervalFired))
    }

    /// In-chat notification that an auto-retain pipeline failed (H3).
    /// The server will still land a fallback summary; this pill surfaces
    /// the quality signal to the user.
    static func memoryAutoRetainFailed(intervalFired: Int, reason: String) -> ChatMessage {
        ChatMessage(role: .system, content: .memoryAutoRetainFailed(intervalFired: intervalFired, reason: reason))
    }

    /// In-chat notification for memory retained to long-term log
    static func memoryRetained(title: String, summary: String?) -> ChatMessage {
        ChatMessage(role: .system, content: .memoryRetained(title: title, summary: summary))
    }

    /// In-chat notification for memory retain with nothing new
    static func memoryRetainedNothingNew() -> ChatMessage {
        ChatMessage(role: .system, content: .memoryRetainedNothingNew)
    }

    /// In-chat notification for rules loaded on session start
    static func rulesLoaded(count: Int) -> ChatMessage {
        ChatMessage(role: .system, content: .rulesLoaded(count: count))
    }

    /// In-chat notification for dynamically activated rules
    static func rulesActivated(rules: [ActivatedRuleEntry], totalActivated: Int) -> ChatMessage {
        ChatMessage(role: .system, content: .rulesActivated(rules: rules, totalActivated: totalActivated))
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
