import Foundation

// MARK: - Agent Methods

struct AgentPromptParams: Encodable {
    let sessionId: String
    let prompt: String
    let images: [ImageAttachment]?
    let attachments: [FileAttachment]?
    let reasoningLevel: String?

    init(
        sessionId: String,
        prompt: String,
        images: [ImageAttachment]? = nil,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil
    ) {
        self.sessionId = sessionId
        self.prompt = prompt
        self.images = images
        self.attachments = attachments
        self.reasoningLevel = reasoningLevel
    }
}

// MARK: - Session-Scoped Skill RPCs

struct SkillActivateParams: Encodable {
    let sessionId: String
    let skillName: String
}

struct SkillDeactivateParams: Encodable {
    let sessionId: String
    let skillName: String
}

struct SpellCastParams: Encodable {
    let sessionId: String
    let spellName: String
}

struct SkillActiveParams: Encodable {
    let sessionId: String
}

struct SkillActivateResult: Decodable {
    let success: Bool
    let alreadyActive: Bool?
    let skill: SkillActivateInfo?

    struct SkillActivateInfo: Decodable {
        let name: String
        let source: String
        let tokens: Int?
    }
}

struct SkillDeactivateResult: Decodable {
    let success: Bool
    let wasActive: Bool?
    let deactivatedSkill: String?
}

struct SpellCastResult: Decodable {
    let success: Bool
    let spell: SpellInfo?

    struct SpellInfo: Decodable {
        let name: String
        let source: String
    }
}

struct SkillActiveResult: Decodable {
    let skills: [ActiveSkillInfo]
    let pendingSpells: [PendingSpellInfo]

    struct ActiveSkillInfo: Decodable {
        let name: String
        let source: String
        let addedVia: String?
        let tokens: Int?
    }

    struct PendingSpellInfo: Decodable {
        let name: String
        let source: String
        let eventId: String
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

/// Tool call info for in-progress turn (used by session.reconstruct inFlight state)
struct CurrentTurnToolCall: Decodable {
    let toolCallId: String
    let toolName: String
    let arguments: [String: AnyCodable]?
    let status: String  // "generating" | "running" | "completed" | "error"
    let result: String?
    let isError: Bool?
    let startedAt: String?
    let completedAt: String?
    /// Progressive output accumulated during execution
    let streamingOutput: String?
}

/// Structured content sequence item (interleaved text/thinking/tool_ref)
enum ContentSequenceItem: Decodable {
    case text(String)
    case thinking(String)
    case toolRef(toolCallId: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, toolCallId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "thinking":
            self = .thinking(try container.decode(String.self, forKey: .thinking))
        case "tool_ref":
            self = .toolRef(toolCallId: try container.decode(String.self, forKey: .toolCallId))
        default:
            self = .text("")
        }
    }
}

// MARK: - Token Usage Types

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

