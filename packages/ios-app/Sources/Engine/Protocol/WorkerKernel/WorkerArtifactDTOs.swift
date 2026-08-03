import Foundation

struct WorkerArtifactContentReferenceDTO: Codable, Equatable, Sendable {
    let kind: String
    let workerId: String
    let artifactId: String
    let contentSha256: String
    let sizeBytes: UInt64
}

struct WorkerArtifactDTO: Codable, Equatable, Identifiable, Sendable {
    let workerId: String
    let artifactId: String
    let displayName: String
    let mediaType: String
    let sizeBytes: UInt64
    let contentSha256: String
    let contentReference: WorkerArtifactContentReferenceDTO
    let sourceInvocationId: String
    let sourceWorkerVersion: String
    let traceId: String
    let createdAt: String

    var id: String { "\(workerId):\(artifactId)" }
}

struct WorkerArtifactStorageAttentionDTO: Codable, Equatable, Sendable {
    let state: String
    let artifactBytes: UInt64
    let databaseBytes: UInt64
    let databaseBudgetBytes: UInt64
    let overBudget: Bool
    let message: String?

    var requiresAttention: Bool { state == "attention" }
}

struct WorkerArtifactPageDTO: Codable, Equatable, Sendable {
    let artifacts: [WorkerArtifactDTO]
    let returned: UInt64
    let total: UInt64
    let nextOffset: UInt64?
    let storageAttention: WorkerArtifactStorageAttentionDTO
}

struct WorkerArtifactContentDTO: Codable, Equatable, Sendable {
    let artifact: WorkerArtifactDTO
    let data: String
}

struct WorkerArtifactDeleteDTO: Codable, Equatable, Sendable {
    let workerId: String
    let artifactId: String
    let deleted: Bool
}

struct WorkerArtifactListRequestDTO: Codable, Equatable, Sendable {
    let limit: UInt16
    let offset: UInt64
}

struct WorkerArtifactIdentityRequestDTO: Codable, Equatable, Sendable {
    let workerId: String
    let artifactId: String
}
