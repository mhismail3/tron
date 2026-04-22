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

struct SkillActiveParams: Encodable {
    let sessionId: String
}

struct SkillActivateResult: Decodable {
    let success: Bool
    let skill: SkillActivateInfo?

    struct SkillActivateInfo: Decodable {
        let name: String
        let source: String
        /// Service folder that produced the skill (`"tron"`, `"claude"`, …).
        let service: String
    }
}

struct SkillDeactivateResult: Decodable {
    let success: Bool
    let deactivatedSkill: String?
}

struct SkillActiveResult: Decodable {
    let skills: [ActiveSkillInfo]

    struct ActiveSkillInfo: Decodable {
        let name: String
        let source: String
        /// Service folder that produced the skill (`"tron"`, `"claude"`, …).
        let service: String
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

struct AgentAbortToolParams: Encodable {
    let sessionId: String
    let toolCallId: String
}

struct AgentAbortToolResult: Decodable {
    let aborted: Bool
}

// MARK: - Prompt Queue RPCs

struct QueuePromptParams: Encodable {
    let sessionId: String
    let prompt: String
}

struct DequeuePromptParams: Encodable {
    let sessionId: String
    let queueId: String
}

struct ClearQueueParams: Encodable {
    let sessionId: String
}

/// Server-side pending queue item (from agent.queuePrompt or reconstruction).
struct PendingQueueItem: Decodable, Identifiable, Equatable {
    let queueId: String
    let text: String
    let position: UInt32
    let timestamp: String

    var id: String { queueId }
}

struct ClearQueueResult: Decodable {
    let cleared: UInt32
}

struct DequeueResult: Decodable {
    let ok: Bool
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

// MARK: - Subagent Result Delivery

struct DeliverSubagentResultsParams: Encodable {
    let sessionId: String
}

// MARK: - Confirmation/Answer Submission

struct SubmitConfirmationParams: Encodable {
    let sessionId: String
    let action: String
    let decision: String
    let note: String?
}

struct AnswerSubmission: Encodable {
    let id: String
    let question: String
    let selectedValues: [String]
    let otherValue: String?
}

struct SubmitAnswersParams: Encodable {
    let sessionId: String
    let questions: [AnswerSubmission]
}

struct SubmitConfirmationResponse: Decodable {
    let acknowledged: Bool
    let queued: Bool
    let runId: String?
}

struct SubmitAnswersResponse: Decodable {
    let acknowledged: Bool
    let queued: Bool
    let runId: String?
}

struct DeliverSubagentResultsResponse: Decodable {
    let acknowledged: Bool
    let queued: Bool
    let subagentCount: Int
    let runId: String?
}

