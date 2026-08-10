import Foundation

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

struct WorkerScheduledWorkRequestDTO: Codable, Equatable, Sendable {
    let limit: UInt64
    let offset: UInt64?
}

struct WorkerInboxDismissRequestDTO: Codable, Equatable, Sendable {
    let inboxId: String
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
    let model: String?
    let reasoningLevel: String?
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

struct WorkerResultHandoffRequestDTO: Codable, Equatable, Sendable {
    let invocationId: String
    let workingDirectory: String
    let model: String
    let title: String
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
