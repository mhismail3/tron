import Foundation

struct CatalogWatchSnapshotRequestDTO: Codable, Equatable, Sendable {
    var afterRevision: UInt64? = nil
    var limit: UInt64? = nil
    var classes: [String]? = nil
    var kinds: [String]? = nil
    var subjectPrefix: String? = nil
    var ownerWorker: String? = nil
}

struct CatalogWatchSnapshotDTO: Codable, Equatable, Sendable {
    var changes: [CatalogChangeDTO]?
    var snapshot: CatalogSnapshotDTO?
    var currentRevision: UInt64?
    var nextRevision: UInt64?
    var hasMore: Bool?
}

struct CatalogSnapshotDTO: Codable, Equatable, Sendable {
    var functions: [AnyCodable]?
    var workers: [AnyCodable]?
    var triggers: [AnyCodable]?
    var triggerTypes: [AnyCodable]?
}

struct CatalogChangeDTO: Codable, Equatable, Sendable {
    var id: String?
    var beforeRevision: UInt64?
    var afterRevision: UInt64?
    var kind: String?
    var subjectId: String?
    var subjectKind: String?
    var changeClass: String?
    var visibility: String?
    var sessionId: String?
    var workspaceId: String?
    var ownerWorker: String?
    var timestamp: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case beforeRevision
        case afterRevision
        case kind
        case subjectId
        case subjectKind
        case changeClass = "class"
        case visibility
        case sessionId
        case workspaceId
        case ownerWorker
        case timestamp
    }
}

struct EngineSurfaceSnapshotRequestDTO: Codable, Equatable, Sendable {
    let relevanceQuery: String?
}

struct EngineSurfaceToolDTO: Codable, Equatable, Identifiable, Sendable {
    let modelName: String
    let functionId: String
    let functionRevision: UInt64
    let ownerWorker: String
    let workerId: String?
    let workerVersion: String?
    let primitiveGroup: String?
    let selectionReason: String

    var id: String { "\(functionId)@\(functionRevision)" }
}

struct AgentToolSurfaceDTO: Codable, Equatable, Sendable {
    let format: UInt32
    let catalogRevision: UInt64
    let surfaceHash: String
    let fixedToolCount: UInt64
    let projectedWorkerCount: UInt64
    let availableWorkerCount: UInt64
    let tools: [EngineSurfaceToolDTO]
}

struct EngineIntrospectionSnapshotDTO: Codable, Equatable, Sendable {
    let format: UInt32
    let autonomousWorkers: Bool
    let dispatchStopped: Bool
    let surface: AgentToolSurfaceDTO
    let workers: [WorkerSummaryDTO]
}
