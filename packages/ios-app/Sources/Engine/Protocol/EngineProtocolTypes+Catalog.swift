import Foundation

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

    var id: String { workerId }
}

struct AgentToolSurfaceDTO: Codable, Equatable, Sendable {
    let catalogRevision: UInt64
    let surfaceHash: String
    let fixedToolCount: UInt64
    let projectedWorkerCount: UInt64
    let availableWorkerCount: UInt64
    let availableWorkers: [AvailableWorkerToolDTO]
}

struct EngineHookOwnerDTO: Codable, Equatable, Identifiable, Sendable {
    let hook: String
    let workerId: String
    let workerVersion: String

    var id: String { hook }
}

struct EngineIntrospectionSnapshotDTO: Codable, Equatable, Sendable {
    let dispatchStopped: Bool
    let activeEngineHooks: [EngineHookOwnerDTO]
    let fixedTools: [EngineSurfaceToolDTO]
    let surface: AgentToolSurfaceDTO
    let workers: [WorkerSummaryDTO]
}
