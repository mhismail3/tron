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
        default:
            return nil
        }
    }

    /// Create a user message with optional attachments, skills, and spells
    static func user(_ text: String, attachments: [Attachment]? = nil, skills: [Skill]? = nil, spells: [Skill]? = nil) -> ChatMessage {
        ChatMessage(role: .user, content: .text(text), attachments: attachments, skills: skills, spells: spells)
    }

    static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: .text(text))
    }

    static func streaming(_ text: String = "") -> ChatMessage {
        ChatMessage(role: .assistant, content: .streaming(text), isStreaming: true)
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
    static func compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String? = nil) -> ChatMessage {
        ChatMessage(role: .system, content: .compaction(tokensBefore: tokensBefore, tokensAfter: tokensAfter, reason: reason, summary: summary))
    }

    /// In-chat notification for context clearing
    static func contextCleared(tokensBefore: Int, tokensAfter: Int) -> ChatMessage {
        ChatMessage(role: .system, content: .contextCleared(tokensBefore: tokensBefore, tokensAfter: tokensAfter))
    }

    /// In-chat notification for message deletion from context
    static func messageDeleted(targetType: String) -> ChatMessage {
        ChatMessage(role: .system, content: .messageDeleted(targetType: targetType))
    }

    /// In-chat notification for skill removal from context
    static func skillRemoved(skillName: String) -> ChatMessage {
        ChatMessage(role: .system, content: .skillRemoved(skillName: skillName))
    }

    /// In-chat notification for rules loaded on session start
    static func rulesLoaded(count: Int) -> ChatMessage {
        ChatMessage(role: .system, content: .rulesLoaded(count: count))
    }

    /// In-chat notification for catching up to in-progress session
    static func catchingUp() -> ChatMessage {
        ChatMessage(role: .system, content: .catchingUp)
    }

    /// In-chat notification for memory ledger write in progress (spinner)
    static func memoryUpdating() -> ChatMessage {
        ChatMessage(role: .system, content: .memoryUpdating)
    }

    /// In-chat notification for memory ledger update
    static func memoryUpdated(title: String, entryType: String) -> ChatMessage {
        ChatMessage(role: .system, content: .memoryUpdated(title: title, entryType: entryType))
    }

    /// Thinking block message (appears before the text response)
    static func thinking(_ text: String, isExpanded: Bool = false, isStreaming: Bool = false) -> ChatMessage {
        ChatMessage(role: .assistant, content: .thinking(visible: text, isExpanded: isExpanded, isStreaming: isStreaming))
    }
}
