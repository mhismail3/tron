import Foundation

enum WorkerInboxPayloadDTO: Codable, Equatable, Sendable {
    case referenceReceipt(WorkerResultReceiptDTO)
    case legacyInline(AnyCodable)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            let receipt = try container.decode(WorkerResultReceiptDTO.self)
            if receipt.reference.kind == "worker_result_reference" {
                self = .referenceReceipt(receipt)
                return
            }
        } catch {
            if let raw = try? container.decode(AnyCodable.self),
               let reference = raw.dictionaryValue?["reference"] as? [String: Any],
               reference["kind"] as? String == "worker_result_reference" {
                throw error
            }
        }
        self = .legacyInline(try container.decode(AnyCodable.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .referenceReceipt(let receipt):
            try container.encode(receipt)
        case .legacyInline(let value):
            try container.encode(value)
        }
    }

    var receipt: WorkerResultReceiptDTO? {
        guard case .referenceReceipt(let receipt) = self else { return nil }
        return receipt
    }

    var legacyInline: AnyCodable? {
        guard case .legacyInline(let value) = self else { return nil }
        return value
    }
}

struct WorkerInboxItemDTO: Codable, Equatable, Identifiable, Sendable {
    let inboxId: String
    let invocationId: String
    let workerId: String
    let severity: String
    let result: WorkerInboxPayloadDTO
    let contextAttached: Bool
    let createdAt: String
    let triggerKind: String
    let hasInvocation: Bool
    let requiresAttention: Bool
    let operatorDisposition: String?
    let operatorResolvedAt: String?

    var id: String { inboxId }

    init(
        inboxId: String,
        invocationId: String,
        workerId: String,
        severity: String,
        result: AnyCodable,
        contextAttached: Bool,
        createdAt: String,
        triggerKind: String,
        hasInvocation: Bool,
        requiresAttention: Bool,
        operatorDisposition: String? = nil,
        operatorResolvedAt: String? = nil
    ) {
        self.inboxId = inboxId
        self.invocationId = invocationId
        self.workerId = workerId
        self.severity = severity
        self.result = .legacyInline(result)
        self.contextAttached = contextAttached
        self.createdAt = createdAt
        self.triggerKind = triggerKind
        self.hasInvocation = hasInvocation
        self.requiresAttention = requiresAttention
        self.operatorDisposition = operatorDisposition
        self.operatorResolvedAt = operatorResolvedAt
    }
}

struct WorkerInboxDismissResultDTO: Codable, Equatable, Sendable {
    let inboxId: String
    let disposition: String
    let resolvedAt: String
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
