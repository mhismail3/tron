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
    let audience: String?
    let accessPath: String?
    let selectionReason: String
    let omissionReason: String?

    var id: String { "\(functionId)@\(functionRevision)" }

    init(
        modelName: String,
        functionId: String,
        functionRevision: UInt64,
        ownerWorker: String,
        description: String,
        inputSchema: AnyCodable,
        outputSchema: AnyCodable?,
        effectClass: String,
        risk: String,
        exposed: Bool,
        workerId: String?,
        workerVersion: String?,
        primitiveGroup: String?,
        audience: String? = nil,
        accessPath: String? = nil,
        selectionReason: String,
        omissionReason: String? = nil
    ) {
        self.modelName = modelName
        self.functionId = functionId
        self.functionRevision = functionRevision
        self.ownerWorker = ownerWorker
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.effectClass = effectClass
        self.risk = risk
        self.exposed = exposed
        self.workerId = workerId
        self.workerVersion = workerVersion
        self.primitiveGroup = primitiveGroup
        self.audience = audience
        self.accessPath = accessPath
        self.selectionReason = selectionReason
        self.omissionReason = omissionReason
    }
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
    let omissionReason: String?
    let rankingMechanism: String?
    let relevanceScore: UInt64
    let completedRuns: UInt64

    var id: String { workerId }

    init(
        workerId: String,
        modelName: String,
        functionId: String,
        functionRevision: UInt64,
        workerVersion: String?,
        promoted: Bool,
        projected: Bool,
        selectionReason: String?,
        omissionReason: String? = nil,
        rankingMechanism: String? = nil,
        relevanceScore: UInt64,
        completedRuns: UInt64
    ) {
        self.workerId = workerId
        self.modelName = modelName
        self.functionId = functionId
        self.functionRevision = functionRevision
        self.workerVersion = workerVersion
        self.promoted = promoted
        self.projected = projected
        self.selectionReason = selectionReason
        self.omissionReason = omissionReason
        self.rankingMechanism = rankingMechanism
        self.relevanceScore = relevanceScore
        self.completedRuns = completedRuns
    }
}

struct AgentToolSurfaceDTO: Codable, Equatable, Sendable {
    let catalogRevision: UInt64
    let surfaceHash: String
    let fixedToolCount: UInt64
    let ordinaryFixedToolCount: UInt64?
    let specialistFixedToolCount: UInt64?
    let conditionalFixedToolCount: UInt64?
    let projectedWorkerCount: UInt64
    let availableWorkerCount: UInt64
    let availableWorkers: [AvailableWorkerToolDTO]
    let rankingMechanism: String?

    init(
        catalogRevision: UInt64,
        surfaceHash: String,
        fixedToolCount: UInt64,
        ordinaryFixedToolCount: UInt64? = nil,
        specialistFixedToolCount: UInt64? = nil,
        conditionalFixedToolCount: UInt64? = nil,
        projectedWorkerCount: UInt64,
        availableWorkerCount: UInt64,
        availableWorkers: [AvailableWorkerToolDTO],
        rankingMechanism: String? = nil
    ) {
        self.catalogRevision = catalogRevision
        self.surfaceHash = surfaceHash
        self.fixedToolCount = fixedToolCount
        self.ordinaryFixedToolCount = ordinaryFixedToolCount
        self.specialistFixedToolCount = specialistFixedToolCount
        self.conditionalFixedToolCount = conditionalFixedToolCount
        self.projectedWorkerCount = projectedWorkerCount
        self.availableWorkerCount = availableWorkerCount
        self.availableWorkers = availableWorkers
        self.rankingMechanism = rankingMechanism
    }
}

struct EngineHookOwnerDTO: Codable, Equatable, Identifiable, Sendable {
    let hook: String
    let workerId: String
    let workerVersion: String

    var id: String { hook }
}

struct ClientActionOwnerDTO: Codable, Equatable, Identifiable, Sendable {
    let action: String
    let workerId: String
    let workerVersion: String

    var id: String { action }
}

struct WorkerArchitectureEdgeDTO: Codable, Equatable, Identifiable, Sendable {
    let kind: String
    let label: String
    let targetWorkerId: String?
    let responseOwner: String?

    var id: String { "\(kind):\(label):\(targetWorkerId ?? "fixed")" }
}

struct WorkerArchitecturePresentationDTO: Codable, Equatable, Sendable {
    let suiteId: String?
    let componentRole: String?
    let primary: Bool
}

struct WorkerArchitectureNodeDTO: Codable, Equatable, Identifiable, Sendable {
    let workerId: String
    let name: String
    let description: String
    let activeVersion: String
    let health: String
    let modelExposure: String
    let runnerKind: String
    let runnerModel: String?
    let engineHooks: [String]
    let clientActions: [String]
    let clientDeliveries: [String]
    let triggerKinds: [String]
    let calls: [WorkerArchitectureEdgeDTO]
    let presentation: WorkerArchitecturePresentationDTO
    let provenance: [AnyCodable]

    var id: String { workerId }
}

struct EngineIntrospectionSnapshotDTO: Codable, Equatable, Sendable {
    let dispatchStopped: Bool
    let activeEngineHooks: [EngineHookOwnerDTO]
    let activeClientActions: [ClientActionOwnerDTO]
    let fixedTools: [EngineSurfaceToolDTO]
    let surface: AgentToolSurfaceDTO
    let workers: [WorkerSummaryDTO]
    let workerArchitecture: [WorkerArchitectureNodeDTO]?

    init(
        dispatchStopped: Bool,
        activeEngineHooks: [EngineHookOwnerDTO],
        activeClientActions: [ClientActionOwnerDTO],
        fixedTools: [EngineSurfaceToolDTO],
        surface: AgentToolSurfaceDTO,
        workers: [WorkerSummaryDTO],
        workerArchitecture: [WorkerArchitectureNodeDTO]? = nil
    ) {
        self.dispatchStopped = dispatchStopped
        self.activeEngineHooks = activeEngineHooks
        self.activeClientActions = activeClientActions
        self.fixedTools = fixedTools
        self.surface = surface
        self.workers = workers
        self.workerArchitecture = workerArchitecture
    }
}
