import Foundation

/// Server-authored permission for one role-review operation. The client never
/// infers mutation authority from proposal status.
struct WorkerRoleReviewActionDTO: Codable, Equatable, Identifiable, Sendable {
    let action: String
    let allowed: Bool
    let disabledReason: String?

    var id: String { action }
}

struct WorkerRoleReviewerDTO: Codable, Equatable, Sendable {
    let available: Bool
    let workerId: String?
    let workerVersion: String?
    let repairRequirement: String?
}

struct WorkerRoleReviewProposalDTO: Codable, Equatable, Identifiable, Sendable {
    let proposalId: String
    let schemaVersion: UInt64
    let proposalHash: String
    let targetWorkerId: String
    let targetWorkerVersion: String
    let targetContentHash: String
    let reviewerWorkerId: String
    let reviewerWorkerVersion: String
    let reviewerInvocationId: String?
    let status: String
    let agentRole: AnyCodable
    let rationale: String
    let publishedVersion: String?
    let lastError: String?
    let rejectionReason: String?
    let createdAt: String
    let updatedAt: String
    let appliedAt: String?
    let rejectedAt: String?
    let allowedActions: [WorkerRoleReviewActionDTO]

    var id: String { proposalId }

    private enum CodingKeys: String, CodingKey {
        case proposalId, schemaVersion, proposalHash
        case targetWorkerId, targetWorkerVersion, targetContentHash
        case reviewerWorkerId, reviewerWorkerVersion
        case reviewerInvocationId
        case status, agentRole, rationale, publishedVersion, lastError, rejectionReason
        case createdAt, updatedAt, appliedAt, rejectedAt, allowedActions
    }

    init(
        proposalId: String,
        schemaVersion: UInt64,
        proposalHash: String,
        targetWorkerId: String,
        targetWorkerVersion: String,
        targetContentHash: String,
        reviewerWorkerId: String,
        reviewerWorkerVersion: String,
        reviewerInvocationId: String? = nil,
        status: String,
        agentRole: AnyCodable,
        rationale: String,
        publishedVersion: String? = nil,
        lastError: String? = nil,
        rejectionReason: String? = nil,
        createdAt: String,
        updatedAt: String,
        appliedAt: String? = nil,
        rejectedAt: String? = nil,
        allowedActions: [WorkerRoleReviewActionDTO] = []
    ) {
        self.proposalId = proposalId
        self.schemaVersion = schemaVersion
        self.proposalHash = proposalHash
        self.targetWorkerId = targetWorkerId
        self.targetWorkerVersion = targetWorkerVersion
        self.targetContentHash = targetContentHash
        self.reviewerWorkerId = reviewerWorkerId
        self.reviewerWorkerVersion = reviewerWorkerVersion
        self.reviewerInvocationId = reviewerInvocationId
        self.status = status
        self.agentRole = agentRole
        self.rationale = rationale
        self.publishedVersion = publishedVersion
        self.lastError = lastError
        self.rejectionReason = rejectionReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.appliedAt = appliedAt
        self.rejectedAt = rejectedAt
        self.allowedActions = allowedActions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        proposalId = try container.decode(String.self, forKey: .proposalId)
        schemaVersion = try container.decodeIfPresent(UInt64.self, forKey: .schemaVersion) ?? 1
        proposalHash = try container.decode(String.self, forKey: .proposalHash)
        targetWorkerId = try container.decode(String.self, forKey: .targetWorkerId)
        targetWorkerVersion = try container.decode(String.self, forKey: .targetWorkerVersion)
        targetContentHash = try container.decode(String.self, forKey: .targetContentHash)
        reviewerWorkerId = try container.decode(String.self, forKey: .reviewerWorkerId)
        reviewerWorkerVersion = try container.decode(String.self, forKey: .reviewerWorkerVersion)
        reviewerInvocationId = try container.decodeIfPresent(String.self, forKey: .reviewerInvocationId)
        status = try container.decode(String.self, forKey: .status)
        agentRole = try container.decode(AnyCodable.self, forKey: .agentRole)
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        publishedVersion = try container.decodeIfPresent(String.self, forKey: .publishedVersion)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        rejectionReason = try container.decodeIfPresent(String.self, forKey: .rejectionReason)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        appliedAt = try container.decodeIfPresent(String.self, forKey: .appliedAt)
        rejectedAt = try container.decodeIfPresent(String.self, forKey: .rejectedAt)
        allowedActions = try container.decodeIfPresent(
            [WorkerRoleReviewActionDTO].self,
            forKey: .allowedActions
        ) ?? []
    }

    func action(_ name: String) -> WorkerRoleReviewActionDTO? {
        allowedActions.first { $0.action == name }
    }
}

struct WorkerRoleReviewItemDTO: Codable, Equatable, Identifiable, Sendable {
    let workerId: String
    let name: String
    let description: String
    let targetVersion: String
    let classification: String
    let proposal: WorkerRoleReviewProposalDTO?
    let allowedActions: [WorkerRoleReviewActionDTO]

    var id: String { workerId }

    private enum CodingKeys: String, CodingKey {
        case workerId, name, description, targetVersion, classification
        case proposal, allowedActions
    }

    init(
        workerId: String,
        name: String,
        description: String,
        targetVersion: String,
        classification: String,
        proposal: WorkerRoleReviewProposalDTO? = nil,
        allowedActions: [WorkerRoleReviewActionDTO] = []
    ) {
        self.workerId = workerId
        self.name = name
        self.description = description
        self.targetVersion = targetVersion
        self.classification = classification
        self.proposal = proposal
        self.allowedActions = allowedActions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workerId = try container.decode(String.self, forKey: .workerId)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        targetVersion = try container.decode(String.self, forKey: .targetVersion)
        classification = try container.decode(String.self, forKey: .classification)
        proposal = try container.decodeIfPresent(
            WorkerRoleReviewProposalDTO.self,
            forKey: .proposal
        )
        allowedActions = try container.decodeIfPresent(
            [WorkerRoleReviewActionDTO].self,
            forKey: .allowedActions
        ) ?? []
    }

    func action(_ name: String) -> WorkerRoleReviewActionDTO? {
        allowedActions.first { $0.action == name }
    }
}

struct WorkerRoleReviewListDTO: Codable, Equatable, Sendable {
    let capability: String
    let reviewer: WorkerRoleReviewerDTO
    let items: [WorkerRoleReviewItemDTO]
    let queueReturned: UInt64
    let queueTotal: UInt64
    let queueTruncated: Bool
    let queueNextOffset: UInt64?
    let proposals: [WorkerRoleReviewProposalDTO]
    let returned: UInt64
    let total: UInt64
    let nextOffset: UInt64?

    private enum CodingKeys: String, CodingKey {
        case capability, reviewer, items, queueReturned, queueTotal, queueTruncated
        case queueNextOffset
        case proposals, returned, total, nextOffset
    }

    init(
        capability: String,
        reviewer: WorkerRoleReviewerDTO,
        items: [WorkerRoleReviewItemDTO],
        queueReturned: UInt64? = nil,
        queueTotal: UInt64? = nil,
        queueTruncated: Bool = false,
        queueNextOffset: UInt64? = nil,
        proposals: [WorkerRoleReviewProposalDTO] = [],
        returned: UInt64? = nil,
        total: UInt64? = nil,
        nextOffset: UInt64? = nil
    ) {
        self.capability = capability
        self.reviewer = reviewer
        self.items = items
        self.queueReturned = queueReturned ?? UInt64(items.count)
        self.queueTotal = queueTotal ?? UInt64(items.count)
        self.queueTruncated = queueTruncated
        self.queueNextOffset = queueNextOffset
        self.proposals = proposals
        self.returned = returned ?? UInt64(proposals.count)
        self.total = total ?? UInt64(proposals.count)
        self.nextOffset = nextOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capability = try container.decode(String.self, forKey: .capability)
        reviewer = try container.decode(WorkerRoleReviewerDTO.self, forKey: .reviewer)
        items = try container.decodeIfPresent(
            [WorkerRoleReviewItemDTO].self,
            forKey: .items
        ) ?? []
        queueReturned = try container.decodeIfPresent(UInt64.self, forKey: .queueReturned)
            ?? UInt64(items.count)
        queueTotal = try container.decodeIfPresent(UInt64.self, forKey: .queueTotal)
            ?? UInt64(items.count)
        queueTruncated = try container.decodeIfPresent(Bool.self, forKey: .queueTruncated)
            ?? (queueTotal > UInt64(items.count))
        queueNextOffset = try container.decodeIfPresent(UInt64.self, forKey: .queueNextOffset)
        proposals = try container.decodeIfPresent(
            [WorkerRoleReviewProposalDTO].self,
            forKey: .proposals
        ) ?? []
        returned = try container.decodeIfPresent(UInt64.self, forKey: .returned)
            ?? UInt64(proposals.count)
        total = try container.decodeIfPresent(UInt64.self, forKey: .total)
            ?? UInt64(proposals.count)
        nextOffset = try container.decodeIfPresent(UInt64.self, forKey: .nextOffset)
    }
}

struct WorkerRoleReviewApplyResultDTO: Codable, Equatable, Sendable {
    let proposal: WorkerRoleReviewProposalDTO
    let worker: WorkerSummaryDTO
}

struct WorkerRoleReviewsRequestDTO: Codable, Equatable, Sendable {
    let limit: UInt64?
    let offset: UInt64?
    let queueLimit: UInt64?
    let queueOffset: UInt64?
}

struct WorkerRoleReviewStartRequestDTO: Codable, Equatable, Sendable {
    let workerId: String
}

struct WorkerRoleReviewInspectRequestDTO: Codable, Equatable, Sendable {
    let proposalId: String
}

struct WorkerRoleReviewApplyRequestDTO: Codable, Equatable, Sendable {
    let proposalId: String
    let confirmed: Bool
}

struct WorkerRoleReviewRejectRequestDTO: Codable, Equatable, Sendable {
    let proposalId: String
    let reason: String?
}
