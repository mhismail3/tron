import Foundation

// MARK: - Agent Methods

struct AgentPromptParams: Encodable {
    let sessionId: String
    let prompt: String
    let attachments: [FileAttachment]?
    let reasoningLevel: String?

    init(
        sessionId: String,
        prompt: String,
        attachments: [FileAttachment]? = nil,
        reasoningLevel: String? = nil
    ) {
        self.sessionId = sessionId
        self.prompt = prompt
        self.attachments = attachments
        self.reasoningLevel = reasoningLevel
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

struct AgentAbortInvocationParams: Encodable {
    let sessionId: String
    let invocationId: String
}

struct AgentAbortInvocationResult: Decodable {
    let aborted: Bool
}

// MARK: - Prompt Queue engine protocols

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

/// Capability invocation info for in-progress turn (used by session::reconstruct inFlight state)
struct CurrentTurnCapabilityInvocation: Decodable {
    let invocationId: String
    let arguments: [String: AnyCodable]?
    let status: String  // "generating" | "running" | "completed" | "error"
    let result: String?
    let isError: Bool?
    let startedAt: String?
    let completedAt: String?
    /// Progressive output accumulated during execution
    let streamingOutput: String?
    let modelPrimitiveName: String?
    let operationName: String?
    let operation: String?
    let traceId: String?
    let rootInvocationId: String?
    let themeColor: String?
    let presentationHints: [String: AnyCodable]?
}

/// Structured content sequence item (interleaved text/thinking/capability_ref)
enum ContentSequenceItem: Decodable {
    case text(String)
    case thinking(String)
    case capabilityRef(invocationId: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, invocationId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "thinking":
            self = .thinking(try container.decode(String.self, forKey: .thinking))
        case "capability_ref":
            self = .capabilityRef(invocationId: try container.decode(String.self, forKey: .invocationId))
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
