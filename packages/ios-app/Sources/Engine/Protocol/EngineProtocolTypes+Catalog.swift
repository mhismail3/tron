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
    let description: String
    let inputSchema: AnyCodable
    let outputSchema: AnyCodable?
    let effectClass: String
    let risk: String
    let health: String
    let exposed: Bool
    let workerId: String?
    let workerVersion: String?
    let primitiveGroup: String?
    let selectionReason: String

    var id: String { "\(functionId)@\(functionRevision)" }
}

struct AvailableWorkerToolDTO: Codable, Equatable, Identifiable, Sendable {
    let workerId: String
    let modelName: String
    let functionId: String
    let functionRevision: UInt64
    let workerVersion: String?
    let promoted: Bool
    let projected: Bool
    let selectionReason: String?
    let relevanceScore: UInt64
    let completedRuns: UInt64
    let health: String

    var id: String { workerId }
}

struct EngineCoreComponentDTO: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let role: String
    let category: String
    let status: String
}

struct AgentToolSurfaceDTO: Codable, Equatable, Sendable {
    let format: UInt32
    let catalogRevision: UInt64
    let surfaceHash: String
    let fixedToolCount: UInt64
    let projectedWorkerCount: UInt64
    let availableWorkerCount: UInt64
    let tools: [EngineSurfaceToolDTO]
    let availableWorkers: [AvailableWorkerToolDTO]
}

struct EngineIntrospectionSnapshotDTO: Codable, Equatable, Sendable {
    let format: UInt32
    let autonomousWorkers: Bool
    let dispatchStopped: Bool
    let coreComponents: [EngineCoreComponentDTO]
    let fixedTools: [EngineSurfaceToolDTO]
    let surface: AgentToolSurfaceDTO
    let workers: [WorkerSummaryDTO]
}
