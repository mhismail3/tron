import Foundation

// MARK: - Model Name Formatting

/// Central mapping of model IDs to human-readable display names
private let modelDisplayNames: [String: String] = [
    // Claude 4.5 family
    "claude-opus-4-5-20251101": "Opus 4.5",
    "claude-sonnet-4-5-20250929": "Sonnet 4.5",
    "claude-haiku-4-5-20251001": "Haiku 4.5",

    // Claude 4.1 family
    "claude-opus-4-1-20250805": "Opus 4.1",

    // Claude 4 family
    "claude-opus-4-20250514": "Opus 4",
    "claude-sonnet-4-20250514": "Sonnet 4",

    // Claude 3.7 family
    "claude-3-7-sonnet-20250219": "Sonnet 3.7",

    // Claude 3.5 family
    "claude-3-5-sonnet-20241022": "Sonnet 3.5",
    "claude-3-5-sonnet-20240620": "Sonnet 3.5",
    "claude-3-5-haiku-20241022": "Haiku 3.5",

    // Claude 3 family
    "claude-3-opus-20240229": "Opus 3",
    "claude-3-sonnet-20240229": "Sonnet 3",
    "claude-3-haiku-20240307": "Haiku 3",
]

/// Formats a model ID into a friendly display name using the central mapping
func formatModelDisplayName(_ modelId: String) -> String {
    // Direct lookup first
    if let displayName = modelDisplayNames[modelId] {
        return displayName
    }

    // Fallback: truncate long model IDs
    return modelId.count > 15 ? String(modelId.prefix(15)) + "…" : modelId
}

// MARK: - Chat Message Model

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: MessageContent
    let timestamp: Date
    var isStreaming: Bool
    var tokenUsage: TokenUsage?
    /// Incremental token usage (delta from previous turn) for display purposes
    var incrementalTokens: TokenUsage?
    /// Files attached to this message (unified model - images, PDFs, documents)
    var attachments: [Attachment]?

    // MARK: - Enriched Metadata (Phase 1)
    // These fields come from server-side event store enhancements

    /// Model that generated this response (e.g., "claude-sonnet-4-20250514")
    var model: String?

    /// Response latency in milliseconds
    var latencyMs: Int?

    /// Turn number in the agent loop
    var turnNumber: Int?

    /// Whether extended thinking was used
    var hasThinking: Bool?

    /// Why the turn ended (end_turn, tool_use, max_tokens)
    var stopReason: String?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: MessageContent,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        tokenUsage: TokenUsage? = nil,
        incrementalTokens: TokenUsage? = nil,
        attachments: [Attachment]? = nil,
        model: String? = nil,
        latencyMs: Int? = nil,
        turnNumber: Int? = nil,
        hasThinking: Bool? = nil,
        stopReason: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.tokenUsage = tokenUsage
        self.incrementalTokens = incrementalTokens
        self.attachments = attachments
        self.model = model
        self.latencyMs = latencyMs
        self.turnNumber = turnNumber
        self.hasThinking = hasThinking
        self.stopReason = stopReason
    }

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    // MARK: - Formatted Metadata Helpers

    /// Format latency as human-readable string (e.g., "2.3s" or "450ms")
    var formattedLatency: String? {
        guard let ms = latencyMs else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }

    /// Short model name (e.g., "claude-sonnet-4-20250514" -> "sonnet-4")
    var shortModelName: String? {
        guard let model = model else { return nil }
        return model.compactModelName
    }
}

// MARK: - Message Role

enum MessageRole: String, Codable, Equatable {
    case user
    case assistant
    case system
    case toolResult

    var displayName: String {
        switch self {
        case .user: return "You"
        case .assistant: return "Tron"
        case .system: return "System"
        case .toolResult: return "Tool"
        }
    }
}

// MARK: - Message Content

enum MessageContent: Equatable {
    case text(String)
    case streaming(String)
    case thinking(visible: String, isExpanded: Bool)
    case toolUse(ToolUseData)
    case toolResult(ToolResultData)
    case error(String)
    case images([ImageContent])
    /// Unified attachments (images, PDFs, documents)
    case attachments([Attachment])
    /// In-chat notification for model change
    case modelChange(from: String, to: String)
    /// In-chat notification for interrupted session
    case interrupted
    /// In-chat notification for transcription failure
    case transcriptionFailed
    /// In-chat notification for no speech detected
    case transcriptionNoSpeech
    /// In-chat notification for context compaction
    case compaction(tokensBefore: Int, tokensAfter: Int, reason: String)
    /// In-chat notification for context clearing
    case contextCleared(tokensBefore: Int, tokensAfter: Int)

    var textContent: String {
        switch self {
        case .text(let text), .streaming(let text):
            return text
        case .thinking(let visible, _):
            return visible
        case .toolUse(let tool):
            return "[\(tool.toolName)]"
        case .toolResult(let result):
            return result.content
        case .error(let message):
            return message
        case .images:
            return "[Images]"
        case .attachments(let files):
            let count = files.count
            return "[\(count) \(count == 1 ? "attachment" : "attachments")]"
        case .modelChange(let from, let to):
            return "Switched from \(from) to \(to)"
        case .interrupted:
            return "Session interrupted"
        case .transcriptionFailed:
            return "Transcription failed"
        case .transcriptionNoSpeech:
            return "No speech detected"
        case .compaction(let before, let after, _):
            let saved = before - after
            return "Context compacted: \(formatTokens(saved)) tokens saved"
        case .contextCleared(let before, let after):
            let freed = before - after
            return "Context cleared: \(formatTokens(freed)) tokens freed"
        }
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1000 {
            return String(format: "%.1fk", Double(tokens) / 1000.0)
        }
        return "\(tokens)"
    }

    var isToolRelated: Bool {
        switch self {
        case .toolUse, .toolResult:
            return true
        default:
            return false
        }
    }

    var isNotification: Bool {
        switch self {
        case .modelChange, .interrupted, .transcriptionFailed, .transcriptionNoSpeech, .compaction, .contextCleared:
            return true
        default:
            return false
        }
    }
}

// MARK: - Tool Use Data

struct ToolUseData: Equatable {
    let toolName: String
    let toolCallId: String
    let arguments: String
    var status: ToolStatus
    var result: String?
    var durationMs: Int?

    var displayName: String {
        switch toolName.lowercased() {
        case "read": return "Reading file"
        case "write": return "Writing file"
        case "edit": return "Editing file"
        case "bash": return "Running command"
        case "glob": return "Searching files"
        case "grep": return "Searching content"
        case "task": return "Spawning agent"
        case "webfetch": return "Fetching URL"
        case "websearch": return "Searching web"
        default: return toolName
        }
    }

    var truncatedArguments: String {
        if arguments.count > 200 {
            return String(arguments.prefix(200)) + "..."
        }
        return arguments
    }

    var formattedDuration: String? {
        guard let ms = durationMs else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }
}

// MARK: - Tool Status

enum ToolStatus: Equatable {
    case running
    case success
    case error

    var iconName: String {
        switch self {
        case .running: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

// MARK: - Tool Result Data

struct ToolResultData: Equatable {
    let toolCallId: String
    let content: String
    let isError: Bool
    let toolName: String?
    let arguments: String?
    let durationMs: Int?

    init(toolCallId: String, content: String, isError: Bool, toolName: String? = nil, arguments: String? = nil, durationMs: Int? = nil) {
        self.toolCallId = toolCallId
        self.content = content
        self.isError = isError
        self.toolName = toolName
        self.arguments = arguments
        self.durationMs = durationMs
    }

    var truncatedContent: String {
        if content.count > 500 {
            return String(content.prefix(500)) + "..."
        }
        return content
    }
}

// MARK: - Image Content

struct ImageContent: Equatable, Identifiable {
    let id: UUID
    let data: Data
    let mimeType: String

    init(data: Data, mimeType: String = "image/jpeg") {
        self.id = UUID()
        self.data = data
        self.mimeType = mimeType
    }
}

// MARK: - Message Extensions

extension ChatMessage {
    /// Create a user message with optional attachments
    static func user(_ text: String, attachments: [Attachment]? = nil) -> ChatMessage {
        ChatMessage(role: .user, content: .text(text), attachments: attachments)
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

    /// In-chat notification for context compaction
    static func compaction(tokensBefore: Int, tokensAfter: Int, reason: String) -> ChatMessage {
        ChatMessage(role: .system, content: .compaction(tokensBefore: tokensBefore, tokensAfter: tokensAfter, reason: reason))
    }

    /// In-chat notification for context clearing
    static func contextCleared(tokensBefore: Int, tokensAfter: Int) -> ChatMessage {
        ChatMessage(role: .system, content: .contextCleared(tokensBefore: tokensBefore, tokensAfter: tokensAfter))
    }
}
