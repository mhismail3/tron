import Foundation

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
    let requestedModel: String?
    let requestedReasoningLevel: String?
    let effectiveModel: String?
    let effectiveReasoningLevel: String?
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
    let requestedModel: String?
    let requestedReasoningLevel: String?
    let effectiveModel: String?
    let effectiveReasoningLevel: String?
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

/// Integrity-bound pointer to one exact, schema-validated durable worker result.
///
/// The invocation ledger owns the value. Clients use this metadata for
/// presentation and request bounded JSON slices through `worker_result_read`.
