import Foundation

struct WorkerSummaryDTO: Codable, Equatable, Identifiable, Sendable {
    let workerId: String
    let name: String
    let description: String
    let toolName: String
    let runnerKind: String
    let activeVersion: String
    let enabled: Bool
    let retired: Bool
    let health: String
    let triggerCount: UInt64
    let updatedAt: String
    let presentation: WorkerPresentationDTO?

    var id: String { workerId }
}

struct WorkerPresentationDTO: Codable, Equatable, Sendable {
    let experienceId: String
    let contractVersion: UInt32
    let suiteId: String?
    let componentRole: String?
    let primary: Bool
}

struct WorkerListResultDTO: Codable, Equatable, Sendable {
    let workers: [WorkerSummaryDTO]
    let stopAll: Bool
}

struct WorkerVersionDTO: Codable, Equatable, Identifiable, Sendable {
    let version: String
    let contentHash: String
    let createdAt: String

    var id: String { version }
}

struct WorkerTriggerStatusDTO: Codable, Equatable, Identifiable, Sendable {
    let triggerId: String
    let kind: String
    let configuration: AnyCodable
    let tokenConfigured: Bool
    let nextRunAt: String?
    let streamCursor: Int64
    let enabled: Bool

    var id: String { triggerId }
}

struct WorkerInspectResultDTO: Codable, Equatable, Sendable {
    let worker: WorkerSummaryDTO
    let bundle: [String: AnyCodable]
    let versions: [WorkerVersionDTO]
    let triggers: [WorkerTriggerStatusDTO]
    let audit: [WorkerAuditDTO]
    let versionDirectory: String
}

struct WorkerAuditDTO: Codable, Equatable, Identifiable, Sendable {
    let auditId: String
    let workerId: String
    let action: String
    let details: AnyCodable
    let createdAt: String

    var id: String { auditId }
}

struct WorkerInvocationDTO: Codable, Equatable, Identifiable, Sendable {
    let invocationId: String
    let workerId: String
    let workerVersion: String
    let status: String
    let input: AnyCodable
    let output: AnyCodable?
    let error: String?
    let idempotencyKey: String
    let traceId: String
    let causalDepth: UInt32
    let triggerKind: String
    let originSessionId: String?
    let agentSessionId: String?
    let interactionMode: String?
    let detachedAt: String?
    let modelToolInvocationId: String?
    let parentWorkerInvocationId: String?
    let retryOfInvocationId: String?
    let attemptCount: UInt32
    let createdAt: String
    let startedAt: String?
    let completedAt: String?

    var id: String { invocationId }

    init(
        invocationId: String,
        workerId: String,
        workerVersion: String,
        status: String,
        input: AnyCodable,
        output: AnyCodable?,
        error: String?,
        idempotencyKey: String,
        traceId: String,
        causalDepth: UInt32,
        triggerKind: String,
        originSessionId: String?,
        agentSessionId: String?,
        interactionMode: String? = nil,
        detachedAt: String? = nil,
        modelToolInvocationId: String? = nil,
        parentWorkerInvocationId: String? = nil,
        retryOfInvocationId: String? = nil,
        attemptCount: UInt32,
        createdAt: String,
        startedAt: String?,
        completedAt: String?
    ) {
        self.invocationId = invocationId
        self.workerId = workerId
        self.workerVersion = workerVersion
        self.status = status
        self.input = input
        self.output = output
        self.error = error
        self.idempotencyKey = idempotencyKey
        self.traceId = traceId
        self.causalDepth = causalDepth
        self.triggerKind = triggerKind
        self.originSessionId = originSessionId
        self.agentSessionId = agentSessionId
        self.interactionMode = interactionMode
        self.detachedAt = detachedAt
        self.modelToolInvocationId = modelToolInvocationId
        self.parentWorkerInvocationId = parentWorkerInvocationId
        self.retryOfInvocationId = retryOfInvocationId
        self.attemptCount = attemptCount
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

struct WorkerRunsResultDTO: Codable, Equatable, Sendable {
    let detail: String?
    let runs: [WorkerInvocationDTO]
    let graphs: [WorkerRunGraphDTO]?
    let returned: UInt64?
    let truncated: Bool?
    let nextOffset: UInt64?
    let contentTruncated: Bool?

    init(
        detail: String? = nil,
        runs: [WorkerInvocationDTO],
        graphs: [WorkerRunGraphDTO]? = nil,
        returned: UInt64? = nil,
        truncated: Bool? = nil,
        nextOffset: UInt64? = nil,
        contentTruncated: Bool? = nil
    ) {
        self.detail = detail
        self.runs = runs
        self.graphs = graphs
        self.returned = returned
        self.truncated = truncated
        self.nextOffset = nextOffset
        self.contentTruncated = contentTruncated
    }
}

enum WorkerRunStageDTO: String, Codable, Equatable, CaseIterable, Sendable {
    case queued
    case planning
    case specialistExecution = "specialist_execution"
    case retryRepair = "retry_repair"
    case synthesis
    case validation
    case publication
    case detached
    case completed
    case failed
    case cancelled
    case interrupted
}

struct WorkerRunCountsDTO: Codable, Equatable, Sendable {
    let queued: UInt64
    let running: UInt64
    let completed: UInt64
    let failed: UInt64
    let cancelled: UInt64
}

struct WorkerRunTimingDTO: Codable, Equatable, Sendable {
    let queueMs: UInt64
    let executionMs: UInt64
    let wallMs: UInt64
    let modelMs: UInt64
    let childCriticalPathMs: UInt64
    let criticalPathMs: UInt64
    let criticalPathNodeIds: [String]
}

struct WorkerRunUsageDTO: Codable, Equatable, Sendable {
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    let cost: Double
}

struct WorkerRunNodeDTO: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: String
    let parentId: String?
    let invocationId: String?
    let workerId: String?
    let workerName: String?
    let workerVersion: String?
    let runner: String?
    let status: String
    let mode: String?
    let stage: WorkerRunStageDTO?
    let createdAt: String?
    let startedAt: String?
    let completedAt: String?
    let elapsedMs: UInt64
    let queueMs: UInt64?
    let executionMs: UInt64?
    let attemptCount: UInt32?
    let attemptNumber: UInt32?
    let sessionId: String?
    let model: String?
    let turn: Int64?
    let modelToolInvocationId: String?
    let retryOfInvocationId: String?
    let inputTokens: Int64?
    let outputTokens: Int64?
    let cacheReadTokens: Int64?
    let cacheCreationTokens: Int64?
    let cost: Double?
    let resultPreview: String?
    let errorPreview: String?
    let presentation: WorkerPresentationDTO?
}

struct WorkerRunTimelineEntryDTO: Codable, Equatable, Identifiable, Sendable {
    let occurredAt: String
    let nodeId: String
    let stage: WorkerRunStageDTO
    let status: String
    let summary: String
    let technical: Bool
    let invocationId: String?

    var id: String {
        "\(occurredAt)|\(nodeId)|\(stage.rawValue)|\(summary)"
    }
}

struct WorkerRunGraphDTO: Codable, Equatable, Identifiable, Sendable {
    let rootInvocationId: String
    let requestedInvocationId: String
    let modelToolInvocationId: String?
    let originSessionId: String?
    let workerId: String
    let workerName: String
    let requestPreview: String
    let status: String
    let mode: String
    let stage: WorkerRunStageDTO
    let stageLabel: String
    let expectedNextTransition: String?
    let createdAt: String
    let startedAt: String?
    let completedAt: String?
    let elapsedMs: UInt64
    let counts: WorkerRunCountsDTO
    let timing: WorkerRunTimingDTO
    let usage: WorkerRunUsageDTO
    let nodes: [WorkerRunNodeDTO]
    let timeline: [WorkerRunTimelineEntryDTO]
    let resultPreview: String?
    let errorPreview: String?
    let truncated: Bool

    var id: String { rootInvocationId }
}

struct WorkerInboxItemDTO: Codable, Equatable, Identifiable, Sendable {
    let inboxId: String
    let invocationId: String
    let workerId: String
    let severity: String
    let result: AnyCodable
    let contextAttached: Bool
    let createdAt: String
    let triggerKind: String
    let hasInvocation: Bool
    let requiresAttention: Bool

    var id: String { inboxId }
}

struct WorkerInboxResultDTO: Codable, Equatable, Sendable {
    let items: [WorkerInboxItemDTO]
    let truncated: Bool?
    let nextOffset: UInt64?

    init(
        items: [WorkerInboxItemDTO],
        truncated: Bool? = nil,
        nextOffset: UInt64? = nil
    ) {
        self.items = items
        self.truncated = truncated
        self.nextOffset = nextOffset
    }
}

struct WorkerIdRequestDTO: Codable, Equatable, Sendable {
    let workerId: String
}

struct WorkerListRequestDTO: Codable, Equatable, Sendable {
    let includeRetired: Bool
}

struct WorkerInspectRequestDTO: Codable, Equatable, Sendable {
    let workerId: String
    let detail: String
}

struct WorkerRunsRequestDTO: Codable, Equatable, Sendable {
    let workerId: String?
    let originSessionId: String?
    let invocationId: String?
    let modelToolInvocationId: String?
    let status: String?
    let limit: UInt64
    let offset: UInt64?
    let detail: String

    init(
        workerId: String?,
        originSessionId: String?,
        invocationId: String? = nil,
        modelToolInvocationId: String? = nil,
        status: String? = nil,
        limit: UInt64,
        offset: UInt64?,
        detail: String
    ) {
        self.workerId = workerId
        self.originSessionId = originSessionId
        self.invocationId = invocationId
        self.modelToolInvocationId = modelToolInvocationId
        self.status = status
        self.limit = limit
        self.offset = offset
        self.detail = detail
    }
}

struct WorkerInboxRequestDTO: Codable, Equatable, Sendable {
    let workerId: String?
    let limit: UInt64
    let offset: UInt64?
    let detail: String
    let contextAttached: Bool?
    let severity: String?
    let attentionOnly: Bool
}

enum WorkerInvocationMode: String, Codable, Equatable, Sendable {
    case wait
    case enqueue
}

struct WorkerInvokeRequestDTO: Codable, Equatable, Sendable {
    let workerId: String
    let input: AnyCodable
    let idempotencyKey: String
    let mode: WorkerInvocationMode
}

struct WorkerRetryRequestDTO: Codable, Equatable, Sendable {
    let retryOfInvocationId: String
    let mode: WorkerInvocationMode
}

struct WorkerCancelRequestDTO: Codable, Equatable, Sendable {
    let invocationId: String
}

struct WorkerAwaitRequestDTO: Codable, Equatable, Sendable {
    let invocationId: String
    let timeoutSeconds: UInt8
}

struct WorkerAwaitResultDTO: Codable, Equatable, Sendable {
    let invocation: WorkerInvocationDTO
    let timedOut: Bool
}

struct WorkerRollbackRequestDTO: Codable, Equatable, Sendable {
    let workerId: String
    let version: String
}

struct WorkerStopAllRequestDTO: Codable, Equatable, Sendable {
    let stopped: Bool
}

struct WorkerStopAllResultDTO: Codable, Equatable, Sendable {
    let stopped: Bool
}

struct WorkerPurgeResultDTO: Codable, Equatable, Sendable {
    let workerId: String
    let purged: Bool
    let archivePath: String
    let archiveSha256: String
}

struct WorkerWebhookRotateRequestDTO: Codable, Equatable, Sendable {
    let workerId: String
    let triggerId: String
}

struct WorkerWebhookCredentialDTO: Codable, Equatable, Sendable {
    let triggerId: String
    let path: String
    let token: String
}

struct WorkerRollbackResultDTO: Codable, Equatable, Sendable {
    let worker: WorkerSummaryDTO
    let webhooks: [WorkerWebhookCredentialDTO]
}
