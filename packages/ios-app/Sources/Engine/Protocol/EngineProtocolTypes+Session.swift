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
    let deliveryChannel: String?
    let narrative: String?
    let workerId: String?
    let workerVersion: String?
    let invocationId: String?
    let sources: [AnyCodable]
    let detail: String?

    var id: String { "\(kind):\(invocationId ?? outcome)" }
}

extension ContextAutomaticEvaluationDTO {
    private enum CodingKeys: String, CodingKey {
        case kind
        case outcome
        case mechanism
        case deliveryChannel
        case narrative
        case workerId
        case workerVersion
        case invocationId
        case sources
        case detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        outcome = try container.decode(String.self, forKey: .outcome)
        mechanism = try container.decode(String.self, forKey: .mechanism)
        deliveryChannel = try container.decodeIfPresent(String.self, forKey: .deliveryChannel)
        narrative = try container.decodeIfPresent(String.self, forKey: .narrative)
        workerId = try container.decodeIfPresent(String.self, forKey: .workerId)
        workerVersion = try container.decodeIfPresent(String.self, forKey: .workerVersion)
        invocationId = try container.decodeIfPresent(String.self, forKey: .invocationId)
        sources = try container.decodeIfPresent([AnyCodable].self, forKey: .sources) ?? []
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }
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

extension ContextMessageManifestDTO {
    private enum CodingKeys: String, CodingKey {
        case ordinal
        case role
        case contentKinds
        case byteCount
        case sha256
        case preview
        case projection
        case sourceKind
        case sourceEventIds
        case invocationId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ordinal = try container.decode(UInt64.self, forKey: .ordinal)
        role = try container.decode(String.self, forKey: .role)
        contentKinds = try container.decode([String].self, forKey: .contentKinds)
        byteCount = try container.decode(UInt64.self, forKey: .byteCount)
        sha256 = try container.decode(String.self, forKey: .sha256)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        projection = try container.decode(String.self, forKey: .projection)
        sourceKind = try container.decodeIfPresent(String.self, forKey: .sourceKind)
        sourceEventIds = try container.decodeIfPresent(
            [String].self,
            forKey: .sourceEventIds
        ) ?? []
        invocationId = try container.decodeIfPresent(String.self, forKey: .invocationId)
    }
}

struct ContextEnvironmentManifestDTO: Decodable, Equatable, Sendable {
    let workingDirectory: String?
    let serverOrigin: String?
    let sha256: String
}

struct ContextCacheLayoutDTO: Decodable, Equatable, Sendable {
    let stableInstructionBytes: UInt64
    let stableInstructionSha256: String
    let fixedToolCount: UInt64
    let fixedToolSchemaBytes: UInt64
    let fixedToolPrefixSha256: String
    let dynamicToolCount: UInt64
    let dynamicToolSchemaBytes: UInt64
    let dynamicToolsSha256: String
    let requestContextBytes: UInt64
    let requestContextSha256: String?
}

struct ContextAgentDeliveryDTO: Decodable, Equatable, Identifiable, Sendable {
    let deliveryId: String
    let sourceKind: String
    let intent: String?
    let wakePolicy: String
    let boundary: String
    let redelivery: Bool
    let provenance: AnyCodable
    let content: String

    var id: String { deliveryId }
}

struct SessionContextManifestDTO: Decodable, Equatable, Sendable {
    let systemContributions: [ContextSystemContributionDTO]
    let messages: [ContextMessageManifestDTO]
    let toolSurface: AnyCodable
    let automaticContext: [ContextAutomaticEvaluationDTO]
    let agentDeliveries: [ContextAgentDeliveryDTO]
    let environment: ContextEnvironmentManifestDTO
    let cacheLayout: ContextCacheLayoutDTO?
    let systemPromptSha256: String
    let messagesSha256: String
    let toolsSha256: String
    let contextSha256: String
}

extension SessionContextManifestDTO {
    private enum CodingKeys: String, CodingKey {
        case systemContributions
        case messages
        case toolSurface
        case automaticContext
        case agentDeliveries
        case environment
        case cacheLayout
        case systemPromptSha256
        case messagesSha256
        case toolsSha256
        case contextSha256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        systemContributions = try container.decode(
            [ContextSystemContributionDTO].self,
            forKey: .systemContributions
        )
        messages = try container.decode([ContextMessageManifestDTO].self, forKey: .messages)
        toolSurface = try container.decode(AnyCodable.self, forKey: .toolSurface)
        automaticContext = try container.decodeIfPresent(
            [ContextAutomaticEvaluationDTO].self,
            forKey: .automaticContext
        ) ?? []
        agentDeliveries = try container.decodeIfPresent(
            [ContextAgentDeliveryDTO].self,
            forKey: .agentDeliveries
        ) ?? []
        environment = try container.decode(ContextEnvironmentManifestDTO.self, forKey: .environment)
        cacheLayout = try container.decodeIfPresent(ContextCacheLayoutDTO.self, forKey: .cacheLayout)
        systemPromptSha256 = try container.decode(String.self, forKey: .systemPromptSha256)
        messagesSha256 = try container.decode(String.self, forKey: .messagesSha256)
        toolsSha256 = try container.decode(String.self, forKey: .toolsSha256)
        contextSha256 = try container.decode(String.self, forKey: .contextSha256)
    }
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

// MARK: - Durable Agent Updates

struct SessionAgentUpdatesParams: Encodable, Equatable {
    let sessionId: String
    let limit: Int
}

struct SessionAgentUpdateDTO: Decodable, Equatable, Identifiable, Sendable {
    let deliveryId: String
    let status: String
    let sourceKind: String
    let intent: String?
    let sourceSessionId: String?
    let sourceInvocationId: String?
    let sourceTraceId: String?
    let resultInvocationId: String?
    let wakePolicy: String
    let boundary: String
    let causalDepth: UInt64
    let redelivery: Bool
    let leaseCount: UInt64
    let wakeAttempts: UInt64
    let lastError: String?
    let preview: String
    let createdAt: String
    let preparedRunId: String?
    let preparedTurn: UInt64?
    let observedAt: String?
    let cancelledAt: String?
    let expiresAt: String?

    var id: String { deliveryId }
}

struct SessionAgentWaitDTO: Decodable, Equatable, Identifiable, Sendable {
    let waitId: String
    let mode: String
    let status: String
    let deliveryId: String?
    let createdAt: String
    let resolvedAt: String?

    var id: String { waitId }
}

struct SessionAgentUpdatesResultDTO: Decodable, Equatable, Sendable {
    let updates: [SessionAgentUpdateDTO]
    let waits: [SessionAgentWaitDTO]
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
