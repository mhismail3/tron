import Foundation

enum WorkerInvocationOutputDTO: Codable, Equatable, Sendable {
    case reference(WorkerResultReferenceDTO)
    case legacyInline(AnyCodable)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            let reference = try container.decode(WorkerResultReferenceDTO.self)
            if reference.kind == "worker_result_reference" {
                self = .reference(reference)
                return
            }
        } catch {
            if let raw = try? container.decode(AnyCodable.self),
               raw.dictionaryValue?["kind"] as? String == "worker_result_reference" {
                throw error
            }
        }
        self = .legacyInline(try container.decode(AnyCodable.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .reference(let reference):
            try container.encode(reference)
        case .legacyInline(let value):
            try container.encode(value)
        }
    }

    var reference: WorkerResultReferenceDTO? {
        guard case .reference(let reference) = self else { return nil }
        return reference
    }

    var legacyInline: AnyCodable? {
        guard case .legacyInline(let value) = self else { return nil }
        return value
    }

    var presentationValue: AnyCodable {
        switch self {
        case .reference(let reference):
            AnyCodable(reference.dictionary)
        case .legacyInline(let value):
            value
        }
    }
}

struct WorkerInvocationDTO: Codable, Equatable, Identifiable, Sendable {
    let invocationId: String
    let workerId: String
    let workerVersion: String
    let status: String
    let input: AnyCodable
    let output: WorkerInvocationOutputDTO?
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
        self.output = output.map(WorkerInvocationOutputDTO.legacyInline)
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
