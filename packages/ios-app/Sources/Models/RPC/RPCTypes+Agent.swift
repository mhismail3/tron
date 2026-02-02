import Foundation

// MARK: - Agent Methods

/// Skill reference for wire format (sent with prompts)
struct SkillReferenceParam: Encodable {
    let name: String
    let source: String  // "global" or "project"

    init(from skill: Skill) {
        self.name = skill.name
        self.source = skill.source.rawValue
    }
}

struct AgentPromptParams: Encodable {
    let sessionId: String
    let prompt: String
    let images: [ImageAttachment]?
    let attachments: [FileAttachment]?
    let reasoningLevel: String?
    let skills: [SkillReferenceParam]?
    /// Spells (ephemeral skills) - injected for one prompt only, not tracked
    let spells: [SkillReferenceParam]?

    init(
        sessionId: String,
        prompt: String,
        images: [ImageAttachment]? = nil,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil,
        skills: [Skill]? = nil,
        spells: [Skill]? = nil
    ) {
        self.sessionId = sessionId
        self.prompt = prompt
        self.images = images
        self.attachments = attachments
        self.reasoningLevel = reasoningLevel
        self.skills = skills?.map { SkillReferenceParam(from: $0) }
        self.spells = spells?.map { SkillReferenceParam(from: $0) }
    }
}

struct ImageAttachment: Encodable {
    let data: String  // base64 encoded
    let mimeType: String

    init(data: Data, mimeType: String = "image/jpeg") {
        self.data = data.base64EncodedString()
        self.mimeType = mimeType
    }
}

/// Unified file attachment for images, PDFs, and documents
struct FileAttachment: Encodable {
    let data: String  // base64 encoded
    let mimeType: String
    let fileName: String?

    init(data: Data, mimeType: String, fileName: String? = nil) {
        self.data = data.base64EncodedString()
        self.mimeType = mimeType
        self.fileName = fileName
    }

    /// Create from an Attachment model
    init(attachment: Attachment) {
        self.data = attachment.data.base64EncodedString()
        self.mimeType = attachment.mimeType
        self.fileName = attachment.fileName
    }
}

struct AgentPromptResult: Decodable {
    let acknowledged: Bool
}

struct AgentAbortParams: Encodable {
    let sessionId: String
}

struct AgentStateParams: Encodable {
    let sessionId: String
}

/// Tool call info for in-progress turn (for resume support)
struct CurrentTurnToolCall: Decodable {
    let toolCallId: String
    let toolName: String
    let arguments: [String: AnyCodable]?
    let status: String  // "pending" | "running" | "completed" | "error"
    let result: String?
    let isError: Bool?
    let startedAt: String
    let completedAt: String?
}

struct AgentStateResult: Decodable {
    let isRunning: Bool
    let currentTurn: Int
    let messageCount: Int
    let tokenUsage: AgentStateTokenUsage?
    let model: String
    let tools: [String]?  // Server returns this but we don't need it
    /// Accumulated text from current in-progress turn (for resume)
    let currentTurnText: String?
    /// Tool calls from current in-progress turn (for resume)
    let currentTurnToolCalls: [CurrentTurnToolCall]?
    /// Whether the session was interrupted (last assistant message has interrupted flag)
    let wasInterrupted: Bool?
}

// MARK: - Token Usage Types

/// Token usage specifically for agent.getState response (uses different field names)
struct AgentStateTokenUsage: Decodable {
    let input: Int
    let output: Int

    var totalTokens: Int { input + output }
}

struct TokenUsage: Decodable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?

    var totalTokens: Int { inputTokens + outputTokens }

    var formattedInput: String { inputTokens.formattedTokenCount }
    var formattedOutput: String { outputTokens.formattedTokenCount }
    var formattedTotal: String { totalTokens.formattedTokenCount }

    /// Format server-provided cache read tokens (e.g., 20000 → "20k"). Returns nil if not provided or zero.
    var formattedCacheRead: String? {
        guard let tokens = cacheReadTokens, tokens > 0 else { return nil }
        return tokens.formattedTokenCount
    }

    /// Format server-provided cache write tokens. Returns nil if not provided or zero.
    var formattedCacheWrite: String? {
        guard let tokens = cacheCreationTokens, tokens > 0 else { return nil }
        return tokens.formattedTokenCount
    }

    /// Check if server provided any cache tokens to display
    var hasCacheActivity: Bool {
        (cacheReadTokens ?? 0) > 0 || (cacheCreationTokens ?? 0) > 0
    }
}

/// Server-calculated normalized token usage
/// iOS app should use these values directly instead of calculating locally.
/// This eliminates bugs from model switches, session resume/fork, and context shrinks.
struct NormalizedTokenUsage: Decodable, Equatable {
    /// Per-turn NEW tokens (for stats line display)
    let newInputTokens: Int
    /// Output tokens for this turn
    let outputTokens: Int
    /// Total context size in tokens (for progress pill)
    let contextWindowTokens: Int
    /// Raw input tokens from provider
    let rawInputTokens: Int
    /// Tokens read from cache
    let cacheReadTokens: Int
    /// Tokens created in cache
    let cacheCreationTokens: Int

    /// Memberwise initializer (required since we have custom inits)
    init(
        newInputTokens: Int,
        outputTokens: Int,
        contextWindowTokens: Int,
        rawInputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int
    ) {
        self.newInputTokens = newInputTokens
        self.outputTokens = outputTokens
        self.contextWindowTokens = contextWindowTokens
        self.rawInputTokens = rawInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    /// Convenience initializer for parsing from raw dictionary (e.g., from AnyCodable payloads)
    init?(from dict: [String: Any]) {
        guard let newInput = dict["newInputTokens"] as? Int,
              let output = dict["outputTokens"] as? Int,
              let contextWindow = dict["contextWindowTokens"] as? Int else {
            return nil
        }
        self.newInputTokens = newInput
        self.outputTokens = output
        self.contextWindowTokens = contextWindow
        self.rawInputTokens = (dict["rawInputTokens"] as? Int) ?? 0
        self.cacheReadTokens = (dict["cacheReadTokens"] as? Int) ?? 0
        self.cacheCreationTokens = (dict["cacheCreationTokens"] as? Int) ?? 0
    }
}
