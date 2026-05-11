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

struct EngineApprovalRecordDTO: Codable, Equatable, Sendable {
    let approvalId: String
    let functionId: String
    let payload: [String: AnyCodable]?
    let actorId: String?
    let actorKind: String?
    let authorityScopes: [String]?
    let traceId: String?
    let parentInvocationId: String?
    let sessionId: String?
    let workspaceId: String?
    let idempotencyKey: String?
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
