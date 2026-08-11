import Foundation

// MARK: - First-class agent coordination

/// The client deliberately keeps lifecycle/action values as strings. The
/// server owns their meaning and may add states without making an older app
/// fail to decode the rest of the management projection.
struct AgentAllowedActionDTO: Codable, Equatable, Identifiable, Sendable {
    let action: String
    let enabled: Bool
    let disabledReason: String?
    /// Exact current mixed-execution impact for destructive actions. Older
    /// servers omit it; the UI then uses a conservative uncounted warning.
    let affectedCount: UInt64?

    init(
        action: String,
        enabled: Bool,
        disabledReason: String?,
        affectedCount: UInt64? = nil
    ) {
        self.action = action
        self.enabled = enabled
        self.disabledReason = disabledReason
        self.affectedCount = affectedCount
    }

    var id: String { action }
}

struct AgentUsageDTO: Codable, Equatable, Sendable {
    let inputTokens: UInt64
    let outputTokens: UInt64
    let cacheReadTokens: UInt64
    let cacheCreationTokens: UInt64
    let cost: Double
    let wallTimeMs: UInt64

    init(
        inputTokens: UInt64 = 0,
        outputTokens: UInt64 = 0,
        cacheReadTokens: UInt64 = 0,
        cacheCreationTokens: UInt64 = 0,
        cost: Double = 0,
        wallTimeMs: UInt64 = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cost = cost
        self.wallTimeMs = wallTimeMs
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens
        case cost, wallTimeMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(UInt64.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(UInt64.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try container.decodeIfPresent(UInt64.self, forKey: .cacheReadTokens) ?? 0
        cacheCreationTokens = try container.decodeIfPresent(
            UInt64.self,
            forKey: .cacheCreationTokens
        ) ?? 0
        cost = try container.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        wallTimeMs = try container.decodeIfPresent(UInt64.self, forKey: .wallTimeMs) ?? 0
    }
}

struct AgentRelationTotalsDTO: Codable, Equatable, Sendable {
    let active: Int
    let related: Int
}

struct AgentRelationDTO: Codable, Equatable, Identifiable, Sendable {
    let agentId: String
    let relationship: String
    let parentAgentId: String?
    let depth: UInt64
    let status: String
    let statusDetail: String?
    let name: String
    let role: String?
    let taskPreview: String?
    let lastActivityAt: String
    let lastMessagePreview: String?
    let ownUsage: AgentUsageDTO?
    let subtreeUsage: AgentUsageDTO?
    let resultState: String?
    /// Authorized audit identifier. It is never exposed to a model-facing
    /// discovery result and is consumed only by the read-only audit sheet.
    let transcriptSessionId: String?
    let allowedActions: [AgentAllowedActionDTO]

    var id: String { agentId }

    private enum CodingKeys: String, CodingKey {
        case agentId, relationship, parentAgentId, depth, status, statusDetail
        case name, role, taskPreview, lastActivityAt, lastMessagePreview
        case ownUsage, subtreeUsage, resultState, transcriptSessionId, allowedActions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try container.decode(String.self, forKey: .agentId)
        relationship = try container.decode(String.self, forKey: .relationship)
        parentAgentId = try container.decodeIfPresent(String.self, forKey: .parentAgentId)
        depth = try container.decodeIfPresent(UInt64.self, forKey: .depth) ?? 0
        status = try container.decode(String.self, forKey: .status)
        statusDetail = try container.decodeIfPresent(String.self, forKey: .statusDetail)
        name = try container.decode(String.self, forKey: .name)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        taskPreview = try container.decodeIfPresent(String.self, forKey: .taskPreview)
        lastActivityAt = try container.decodeIfPresent(String.self, forKey: .lastActivityAt) ?? ""
        lastMessagePreview = try container.decodeIfPresent(
            String.self,
            forKey: .lastMessagePreview
        )
        ownUsage = try container.decodeIfPresent(AgentUsageDTO.self, forKey: .ownUsage)
        subtreeUsage = try container.decodeIfPresent(AgentUsageDTO.self, forKey: .subtreeUsage)
        resultState = try container.decodeIfPresent(String.self, forKey: .resultState)
        transcriptSessionId = try container.decodeIfPresent(
            String.self,
            forKey: .transcriptSessionId
        )
        allowedActions = try container.decodeIfPresent(
            [AgentAllowedActionDTO].self,
            forKey: .allowedActions
        ) ?? []
    }
}

struct AgentRelationsParams: Encodable, Equatable, Sendable {
    let ownerSessionId: String
    let cursor: String?
    let limit: Int
}

struct AgentRelationsResultDTO: Decodable, Equatable, Sendable {
    let totals: AgentRelationTotalsDTO
    let items: [AgentRelationDTO]
    let nextCursor: String?
}

struct AgentRoleDetailDTO: Codable, Equatable, Sendable {
    let roleId: String?
    let name: String
    let summary: String?
    let workerId: String?
    let workerVersion: String?
    let updateAvailable: Bool

    private enum CodingKeys: String, CodingKey {
        case roleId, name, summary, workerId, workerVersion, updateAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roleId = try container.decodeIfPresent(String.self, forKey: .roleId)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "General agent"
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        workerId = try container.decodeIfPresent(String.self, forKey: .workerId)
        workerVersion = try container.decodeIfPresent(String.self, forKey: .workerVersion)
        updateAvailable = try container.decodeIfPresent(Bool.self, forKey: .updateAvailable) ?? false
    }
}

struct AgentGrantDTO: Codable, Equatable, Identifiable, Sendable {
    let functionId: String
    let delegation: String?
    let workspaceEffect: String?

    var id: String { functionId }
}

struct AgentLimitDTO: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let used: Double?
    let limit: Double?
    let unit: String?

    var id: String { name }
}

struct AgentWriteScopeDTO: Codable, Equatable, Identifiable, Sendable {
    let path: String
    let state: String?
    let detail: String?

    var id: String { path }
}

struct AgentLineageItemDTO: Codable, Equatable, Identifiable, Sendable {
    let agentId: String
    let name: String
    let relationship: String
    let status: String?

    var id: String { agentId }
}

struct AgentResultSummaryDTO: Codable, Equatable, Identifiable, Sendable {
    let kind: String
    let status: String
    let preview: String?
    let resultId: String?
    let workerInvocationId: String?
    let value: AnyCodable?

    var id: String { resultId ?? workerInvocationId ?? "\(kind):\(status)" }
}

struct AgentResultReadParams: Encodable, Equatable, Sendable {
    let ownerSessionId: String
    let agentId: String
    let resultId: String
    let pointer: String
    let offset: UInt64
    let limit: UInt8
}

struct AgentResultReferenceDTO: Codable, Equatable, Sendable {
    let kind: String
    let resultId: String
    let assignmentId: String?
    let contentSha256: String
    let sizeBytes: UInt64
    let preview: String
}

struct AgentResultChildDTO: Codable, Equatable, Identifiable, Sendable {
    let pointer: String
    let type: String
    let sizeBytes: UInt64
    let preview: String

    var id: String { pointer }
}

struct AgentResultChunkDTO: Codable, Equatable, Sendable {
    let kind: String
    let reference: AgentResultReferenceDTO
    let pointer: String
    let value: AnyCodable
    let children: [AgentResultChildDTO]
    let offset: UInt64
    let returned: UInt64
    let total: UInt64
    let nextOffset: UInt64?
    let truncated: Bool
}

struct AgentAssignmentDTO: Codable, Equatable, Identifiable, Sendable {
    let assignmentId: String
    let executionId: String?
    let kind: String
    let status: String
    let task: String
    let requesterName: String?
    let requesterAgentId: String?
    let queuePosition: UInt64?
    let createdAt: String
    let startedAt: String?
    let completedAt: String?
    let retryOf: String?
    let failure: String?
    let usage: AgentUsageDTO?
    let result: AgentResultSummaryDTO?
    let allowedActions: [AgentAllowedActionDTO]

    var id: String { assignmentId }

    private enum CodingKeys: String, CodingKey {
        case assignmentId, executionId, kind, status, task, requesterName
        case requesterAgentId, queuePosition, createdAt, startedAt, completedAt
        case retryOf, failure, usage, result, allowedActions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assignmentId = try container.decode(String.self, forKey: .assignmentId)
        executionId = try container.decodeIfPresent(String.self, forKey: .executionId)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "instruction"
        status = try container.decode(String.self, forKey: .status)
        task = try container.decodeIfPresent(String.self, forKey: .task) ?? "Assignment"
        requesterName = try container.decodeIfPresent(String.self, forKey: .requesterName)
        requesterAgentId = try container.decodeIfPresent(String.self, forKey: .requesterAgentId)
        queuePosition = try container.decodeIfPresent(UInt64.self, forKey: .queuePosition)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        retryOf = try container.decodeIfPresent(String.self, forKey: .retryOf)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        usage = try container.decodeIfPresent(AgentUsageDTO.self, forKey: .usage)
        result = try container.decodeIfPresent(AgentResultSummaryDTO.self, forKey: .result)
        allowedActions = try container.decodeIfPresent(
            [AgentAllowedActionDTO].self,
            forKey: .allowedActions
        ) ?? []
    }
}

struct AgentInspectParams: Encodable, Equatable, Sendable {
    let ownerSessionId: String
    let agentId: String
}

struct AgentInspectDTO: Decodable, Equatable, Sendable {
    let agentId: String
    let name: String
    let relationship: String
    let status: String
    let statusDetail: String?
    let taskPreview: String?
    let transcriptSessionId: String?
    let currentAssignment: AgentAssignmentDTO?
    let role: AgentRoleDetailDTO?
    let grants: [AgentGrantDTO]
    let limits: [AgentLimitDTO]
    let writeScopes: [AgentWriteScopeDTO]
    let lineage: [AgentLineageItemDTO]
    let contacts: [AgentLineageItemDTO]
    let ownUsage: AgentUsageDTO?
    let subtreeUsage: AgentUsageDTO?
    let result: AgentResultSummaryDTO?
    let technical: AnyCodable?
    let allowedActions: [AgentAllowedActionDTO]

    private enum CodingKeys: String, CodingKey {
        case agentId, name, relationship, status, statusDetail, taskPreview
        case transcriptSessionId, currentAssignment, role, grants, limits
        case writeScopes, lineage, contacts, ownUsage, subtreeUsage, result
        case technical, allowedActions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try container.decode(String.self, forKey: .agentId)
        name = try container.decode(String.self, forKey: .name)
        relationship = try container.decode(String.self, forKey: .relationship)
        status = try container.decode(String.self, forKey: .status)
        statusDetail = try container.decodeIfPresent(String.self, forKey: .statusDetail)
        taskPreview = try container.decodeIfPresent(String.self, forKey: .taskPreview)
        transcriptSessionId = try container.decodeIfPresent(
            String.self,
            forKey: .transcriptSessionId
        )
        currentAssignment = try container.decodeIfPresent(
            AgentAssignmentDTO.self,
            forKey: .currentAssignment
        )
        role = try container.decodeIfPresent(AgentRoleDetailDTO.self, forKey: .role)
        grants = try container.decodeIfPresent([AgentGrantDTO].self, forKey: .grants) ?? []
        limits = try container.decodeIfPresent([AgentLimitDTO].self, forKey: .limits) ?? []
        writeScopes = try container.decodeIfPresent(
            [AgentWriteScopeDTO].self,
            forKey: .writeScopes
        ) ?? []
        lineage = try container.decodeIfPresent(
            [AgentLineageItemDTO].self,
            forKey: .lineage
        ) ?? []
        contacts = try container.decodeIfPresent(
            [AgentLineageItemDTO].self,
            forKey: .contacts
        ) ?? []
        ownUsage = try container.decodeIfPresent(AgentUsageDTO.self, forKey: .ownUsage)
        subtreeUsage = try container.decodeIfPresent(AgentUsageDTO.self, forKey: .subtreeUsage)
        result = try container.decodeIfPresent(AgentResultSummaryDTO.self, forKey: .result)
        technical = try container.decodeIfPresent(AnyCodable.self, forKey: .technical)
        allowedActions = try container.decodeIfPresent(
            [AgentAllowedActionDTO].self,
            forKey: .allowedActions
        ) ?? []
    }
}

struct AgentAssignmentsParams: Encodable, Equatable, Sendable {
    let ownerSessionId: String
    let agentId: String
    let cursor: String?
    let limit: Int
}

struct AgentAssignmentsResultDTO: Decodable, Equatable, Sendable {
    let items: [AgentAssignmentDTO]
    let nextCursor: String?
}

struct AgentMessageSummaryDTO: Codable, Equatable, Identifiable, Sendable {
    let messageId: String
    let direction: String
    let kind: String
    let provenance: String
    let otherAgentId: String?
    let otherAgentName: String?
    let assignmentId: String?
    let replyTo: String?
    let deliveryState: String
    let preview: String
    let createdAt: String

    var id: String { messageId }
}

struct AgentMessageDetailDTO: Codable, Equatable, Sendable {
    let messageId: String
    let direction: String
    let kind: String
    let provenance: String
    let sourceAgentId: String?
    let sourceAgentName: String?
    let targetAgentId: String?
    let targetAgentName: String?
    let assignmentId: String?
    let replyTo: String?
    let deliveryState: String
    let content: String
    let createdAt: String
    let deliveredAt: String?
    let observedAt: String?
    let redeliveryCount: UInt64?
}

struct AgentMessagesParams: Encodable, Equatable, Sendable {
    let ownerSessionId: String
    let agentId: String
    let cursor: String?
    let limit: Int
}

struct AgentMessagesResultDTO: Decodable, Equatable, Sendable {
    let items: [AgentMessageSummaryDTO]
    let nextCursor: String?
}

struct AgentMessageDetailParams: Encodable, Equatable, Sendable {
    let ownerSessionId: String
    let agentId: String
    let messageId: String
}

struct AgentOperatorMessageParams: Encodable, Equatable, Sendable {
    let ownerSessionId: String
    let agentId: String
    let clientMutationId: String
    let content: String
}

struct AgentManageParams: Encodable, Equatable, Sendable {
    let ownerSessionId: String
    let agentId: String
    let clientMutationId: String
    let action: String
    let assignmentId: String?
    let cascade: Bool?
    let configuration: AnyCodable?
}

struct AgentRetryParams: Encodable, Equatable, Sendable {
    let ownerSessionId: String
    let agentId: String
    let clientMutationId: String
    let assignmentId: String
}

struct AgentPromoteParams: Encodable, Equatable, Sendable {
    let ownerSessionId: String
    let agentId: String
    let clientMutationId: String
}

struct AgentMutationResultDTO: Decodable, Equatable, Sendable {
    let agent: AgentInspectDTO
    let affectedAgentIds: [String]

    private enum CodingKeys: String, CodingKey {
        case agent, affectedAgentIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(AgentInspectDTO.self, forKey: .agent)
        affectedAgentIds = try container.decodeIfPresent(
            [String].self,
            forKey: .affectedAgentIds
        ) ?? [agent.agentId]
    }
}
