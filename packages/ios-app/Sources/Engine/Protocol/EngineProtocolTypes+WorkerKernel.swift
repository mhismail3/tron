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
    let agentSessionId: String?
    let attemptCount: UInt32
    let createdAt: String
    let startedAt: String?
    let completedAt: String?

    var id: String { invocationId }
}

struct WorkerRunsResultDTO: Codable, Equatable, Sendable {
    let runs: [WorkerInvocationDTO]
    let truncated: Bool?
    let nextOffset: UInt64?

    init(
        runs: [WorkerInvocationDTO],
        truncated: Bool? = nil,
        nextOffset: UInt64? = nil
    ) {
        self.runs = runs
        self.truncated = truncated
        self.nextOffset = nextOffset
    }
}

struct WorkerInboxItemDTO: Codable, Equatable, Identifiable, Sendable {
    let inboxId: String
    let invocationId: String
    let workerId: String
    let severity: String
    let result: AnyCodable
    let seen: Bool
    let createdAt: String

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
    let limit: UInt64
    let offset: UInt64?
    let detail: String
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

struct WorkerCancelRequestDTO: Codable, Equatable, Sendable {
    let invocationId: String
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
