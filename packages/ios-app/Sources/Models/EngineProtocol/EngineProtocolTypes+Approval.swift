import Foundation

// MARK: - Engine Approval Primitive DTOs

enum EngineApprovalDecision: String, Codable, Sendable {
    case approve
    case deny
}

enum EngineApprovalStatus: String, Codable, Sendable {
    case pending
    case approved
    case denied
    case executed
    case failed
}

struct EngineApprovalResolveParams: Encodable, Sendable {
    let approvalId: String
    let decision: String
    let sessionId: String?
    let workspaceId: String?
}

struct EngineApprovalAuthorityRequirementDTO: Codable, Equatable, Sendable {
    let scopes: [String]
    let approvalRequired: Bool
}

struct EngineApprovalIdempotencyContractDTO: Codable, Equatable, Sendable {
    let keySource: String
    let dedupeScope: String
    let replayBehavior: String
    let ledgerKind: String
}

struct EngineApprovalResourceLeaseRequirementDTO: Codable, Equatable, Sendable {
    let resolverId: String
    let resourceKind: String
    let resourceIdTemplate: String
    let ttlMs: Int
    let exclusive: Bool
    let streamTopic: String
    let failureBehavior: String
}

struct EngineApprovalCompensationContractDTO: Codable, Equatable, Sendable {
    let kind: String
    let notes: String
}

struct EngineApprovalTargetMetadataDTO: Codable, Equatable, Sendable {
    let effectClass: String
    let riskLevel: String
    let requiredAuthority: EngineApprovalAuthorityRequirementDTO
    let idempotency: EngineApprovalIdempotencyContractDTO?
    let resourceLease: EngineApprovalResourceLeaseRequirementDTO?
    let compensation: EngineApprovalCompensationContractDTO?
}

struct EngineApprovalRecordDTO: Codable, Equatable, Sendable {
    let approvalId: String
    let functionId: String
    let payload: [String: AnyCodable]?
    let actorId: String?
    let actorKind: String?
    let authorityGrantId: String?
    let authorityScopes: [String]?
    let traceId: String?
    let parentInvocationId: String?
    let sessionId: String?
    let workspaceId: String?
    let idempotencyKey: String?
    let targetMetadata: EngineApprovalTargetMetadataDTO?
    let status: EngineApprovalStatus
    let decisionActorId: String?
    let decidedAt: String?
    let createdAt: String?
    let updatedAt: String?
}

struct EngineApprovalResolveResult: Decodable, Sendable {
    let approval: EngineApprovalRecordDTO
    let child: AnyCodable?
}
