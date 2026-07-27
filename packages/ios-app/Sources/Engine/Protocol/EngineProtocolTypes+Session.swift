import Foundation

// MARK: - Session Methods

struct SessionCreateParams: Encodable {
    let workingDirectory: String
    let model: String?
    let title: String?

    init(
        workingDirectory: String,
        model: String? = nil,
        title: String? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.model = model
        self.title = title
    }
}

struct SessionCreateResult: Decodable {
    let sessionId: String
    let model: String
    let createdAt: String
}

struct SessionListParams: Encodable {
    let workingDirectory: String?
    let limit: Int?
    let cursor: String?
    let includeArchived: Bool?
}

struct SessionInfo: Decodable, Identifiable, Hashable {
    let sessionId: String
    let model: String
    let createdAt: String
    let eventCount: Int?
    let turnCount: Int?
    let messageCount: Int
    let inputTokens: Int?
    let outputTokens: Int?
    /// Current context size (input_tokens from last API call)
    let lastTurnInputTokens: Int?
    /// Total tokens read from prompt cache
    let cacheReadTokens: Int?
    /// Total tokens written to prompt cache
    let cacheCreationTokens: Int?
    let cost: Double?
    let lastActivity: String?
    let isActive: Bool
    let isArchived: Bool?
    let workingDirectory: String?
    let parentSessionId: String?
    let title: String?
    /// Last user prompt text (for preview display)
    let lastUserPrompt: String?
    /// Last assistant response text (for preview display)
    let lastAssistantResponse: String?
    /// Whether the agent is currently running in this session (server-authoritative)
    let isRunning: Bool?
    /// Server-computed activity summary lines for session list rows
    let activityLines: [ServerActivityLine]?
    /// Canonical ordinary session tags projected as user-facing labels.
    var labels: [String]? = nil
    /// Canonical single group decoded from the reserved organization tag.
    var organizationGroup: String? = nil

    var id: String { sessionId }

    /// Whether this session is a fork (has a parent session)
    var isFork: Bool { parentSessionId != nil }

    /// Display session ID prefix (first 20 characters)
    var displayName: String {
        String(sessionId.prefix(20))
    }

    var formattedDate: String {
        DateParser.relativeAbbreviated(createdAt)
    }

    /// Total input tokens sent to model (uncached + cache read)
    var totalInputTokens: Int { (inputTokens ?? 0) + (cacheReadTokens ?? 0) }

    var formattedTokens: String {
        TokenFormatter.formatPair(input: totalInputTokens, output: outputTokens ?? 0)
    }

    /// Formatted cache tokens - separate read/creation for visibility
    var formattedCacheTokens: String? {
        let read = cacheReadTokens ?? 0
        let creation = cacheCreationTokens ?? 0
        if read == 0 && creation == 0 { return nil }
        return "⚡\(read.formattedTokenCount) read, ✏\(creation.formattedTokenCount) write"
    }

    /// Formatted cost string (e.g., "$0.12")
    var formattedCost: String {
        let c = cost ?? 0
        if c < 0.01 {
            return "<$0.01"
        }
        return String(format: "$%.2f", c)
    }
}

struct SessionListResult: Decodable {
    let sessions: [SessionInfo]
    let totalCount: Int?
    let hasMore: Bool?
    let nextCursor: String?
    /// Immutable upper creation-time boundary shared by every page.
    let snapshotAsOf: String?
    /// Whether this query covers every session needed for destructive reconciliation.
    let snapshotCanReconcile: Bool?

    init(
        sessions: [SessionInfo],
        totalCount: Int?,
        hasMore: Bool?,
        nextCursor: String?,
        snapshotAsOf: String? = nil,
        snapshotCanReconcile: Bool? = nil
    ) {
        self.sessions = sessions
        self.totalCount = totalCount
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.snapshotAsOf = snapshotAsOf
        self.snapshotCanReconcile = snapshotCanReconcile
    }
}

struct SessionResumeParams: Encodable {
    let sessionId: String
}

struct SessionResumeResult: Decodable {
    let sessionId: String
    let model: String
    let messageCount: Int
    let lastActivity: String
}

struct SessionArchiveParams: Encodable {
    let sessionId: String
}

struct SessionUnarchiveParams: Encodable {
    let sessionId: String
}

struct SessionHistoryParams: Encodable {
    let sessionId: String
    let limit: Int?
    let beforeId: String?
}

struct HistoryMessage: Decodable, Identifiable {
    let id: String
    let role: String
    let content: String
    let timestamp: String
    let toolInvocations: [ToolInvocationInfo]?
}

struct ToolInvocationInfo: Decodable {
    let id: String
    let identity: ToolIdentity?
    let input: [String: AnyCodable]?
    let result: String?
    let isError: Bool?
}

struct SessionHistoryResult: Decodable {
    let messages: [HistoryMessage]
    let hasMore: Bool
}

// MARK: - Inspectable Provider Context

struct SessionContextRequestsParams: Encodable, Equatable {
    let sessionId: String
    let beforeSequence: Int64?
    let limit: Int
}

struct SessionContextRequestDetailParams: Encodable, Equatable {
    let sessionId: String
    let eventId: String
}

struct SessionContextRequestSummaryDTO: Decodable, Equatable, Identifiable, Sendable {
    let eventId: String
    let sequence: Int64
    let timestamp: String
    let format: String
    let turn: UInt64?
    let providerType: String?
    let providerName: String?
    let model: String?
    let requestClassification: String
    let messageCount: UInt64
    let toolCount: UInt64
    let automaticContextCount: UInt64
    let manifestAvailable: Bool
    let provenanceAvailability: String

    var id: String { eventId }
}

struct SessionContextRequestsResultDTO: Decodable, Equatable, Sendable {
    let requests: [SessionContextRequestSummaryDTO]
    let hasMore: Bool
    let nextBeforeSequence: Int64?
}

struct ContextSystemContributionDTO: Decodable, Equatable, Identifiable, Sendable {
    let kind: String
    let label: String
    let content: String
    let byteCount: UInt64
    let sha256: String
    let provenance: AnyCodable?

    var id: String { "\(kind):\(sha256)" }
}

struct ContextAutomaticEvaluationDTO: Decodable, Equatable, Identifiable, Sendable {
    let kind: String
    let outcome: String
    let mechanism: String
    let narrative: String?
    let workerId: String?
    let workerVersion: String?
    let invocationId: String?
    let sources: [AnyCodable]
    let detail: String?

    var id: String { "\(kind):\(invocationId ?? outcome)" }
}

struct ContextMessageManifestDTO: Decodable, Equatable, Identifiable, Sendable {
    let ordinal: UInt64
    let role: String
    let contentKinds: [String]
    let byteCount: UInt64
    let sha256: String
    let preview: String?
    let projection: String
    let sourceKind: String?
    let sourceEventIds: [String]
    let invocationId: String?

    var id: String { "\(ordinal):\(sha256)" }
}

struct ContextEnvironmentManifestDTO: Decodable, Equatable, Sendable {
    let workingDirectory: String?
    let serverOrigin: String?
    let sha256: String
}

struct SessionContextManifestDTO: Decodable, Equatable, Sendable {
    let systemContributions: [ContextSystemContributionDTO]
    let messages: [ContextMessageManifestDTO]
    let toolSurface: AnyCodable
    let automaticContext: [ContextAutomaticEvaluationDTO]
    let environment: ContextEnvironmentManifestDTO
    let systemPromptSha256: String
    let messagesSha256: String
    let toolsSha256: String
    let contextSha256: String
}

struct SessionContextRequestDetailDTO: Decodable, Equatable, Sendable {
    let eventId: String
    let sequence: Int64
    let timestamp: String
    let format: String
    let contextManifest: SessionContextManifestDTO?
    let providerAdditions: [ContextSystemContributionDTO]?
    let providerAudit: AnyCodable
    let provenanceAvailability: String
}

// MARK: - Session Fork

struct SessionForkParams: Encodable {
    let sessionId: String
    let fromEventId: String?  // Event ID to fork from (nil = fork from HEAD)
}

struct SessionForkResult: Decodable {
    let newSessionId: String
    let forkedFromEventId: String?  // The event that was forked from
    let forkedFromSessionId: String?  // The source session
    let rootEventId: String?  // The fork event in the new session
}
