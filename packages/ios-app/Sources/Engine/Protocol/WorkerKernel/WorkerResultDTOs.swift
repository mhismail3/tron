import Foundation

struct WorkerResultReferenceDTO: Codable, Equatable, Sendable {
    let kind: String
    let invocationId: String
    let workerId: String
    let workerVersion: String
    let outputSchemaSha256: String
    let contentSha256: String
    let sizeBytes: UInt64
    let preview: String
    let message: String

    var dictionary: [String: Any] {
        [
            "kind": kind,
            "invocationId": invocationId,
            "workerId": workerId,
            "workerVersion": workerVersion,
            "outputSchemaSha256": outputSchemaSha256,
            "contentSha256": contentSha256,
            "sizeBytes": sizeBytes,
            "preview": preview,
            "message": message,
        ]
    }
}

struct WorkerResultChildDTO: Codable, Equatable, Identifiable, Sendable {
    let pointer: String
    let type: String
    let sizeBytes: UInt64
    let preview: String

    var id: String { pointer }
}

struct WorkerResultReadRequestDTO: Codable, Equatable, Sendable {
    let invocationId: String
    let pointer: String
    let offset: UInt64
    let limit: UInt8
}

struct WorkerResultChunkDTO: Codable, Equatable, Sendable {
    let kind: String
    let reference: WorkerResultReferenceDTO
    let pointer: String
    let value: AnyCodable
    let children: [WorkerResultChildDTO]
    let offset: UInt64
    let returned: UInt64
    let total: UInt64
    let nextOffset: UInt64?
    let truncated: Bool
}

struct WorkerResultReceiptDTO: Codable, Equatable, Sendable {
    let status: String
    let reference: WorkerResultReferenceDTO
    let preview: String
}

/// A visible session created atomically with authority to read one exact
/// durable worker result.
struct WorkerResultHandoffDTO: Codable, Equatable, Sendable {
    let sessionId: String
    let workspaceId: String
    let model: String
    let workingDirectory: String
    let createdAt: String
}
