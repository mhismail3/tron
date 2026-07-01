import Foundation

struct ContextControlResponseDTO: Decodable, Equatable, Sendable {
    let schemaVersion: String?
    let operation: String
    let status: String
    let idempotentReplay: Bool?
    let sessionId: String?
    let contextControlSnapshotResourceId: String?
    let contextControlSnapshotVersionId: String?
    let contextControlActionResourceId: String?
    let contextControlActionVersionId: String?
    let projection: [String: AnyCodable]
}

private struct ContextControlSnapshotRequestDTO: Encodable {
    let sessionId: String
    let idempotencyKey: String
}

private struct ContextControlActionRequestDTO: Encodable {
    let sessionId: String
    let reason: String
    let idempotencyKey: String
}

private struct ContextControlActionListRequestDTO: Encodable {
    let sessionId: String
    let limit: Int
}

private struct ContextControlActionInspectRequestDTO: Encodable {
    let sessionId: String
    let contextControlActionResourceId: String
}

@MainActor
protocol ContextControlRepository: AnyObject {
    func snapshot(sessionId: String) async throws -> ContextControlResponseDTO
    func compact(sessionId: String, reason: String) async throws -> ContextControlResponseDTO
    func clear(sessionId: String, reason: String) async throws -> ContextControlResponseDTO
    func actionList(sessionId: String, limit: Int) async throws -> ContextControlResponseDTO
    func actionInspect(sessionId: String, actionResourceId: String) async throws -> ContextControlResponseDTO
}

final class ContextControlClient: EngineDomainClient, ContextControlRepository {
    func snapshot(sessionId: String) async throws -> ContextControlResponseDTO {
        _ = try requireTransport().requireConnection()
        let idempotencyKey = EngineIdempotencyKey.userAction("contextControl.snapshot")
        return try await invokeWrite(
            "context_control::ui_snapshot",
            ContextControlSnapshotRequestDTO(
                sessionId: sessionId,
                idempotencyKey: idempotencyKey.rawValue
            ),
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    func compact(sessionId: String, reason: String) async throws -> ContextControlResponseDTO {
        _ = try requireTransport().requireConnection()
        let idempotencyKey = EngineIdempotencyKey.userAction("contextControl.compact")
        return try await invokeWrite(
            "context_control::ui_compact",
            ContextControlActionRequestDTO(
                sessionId: sessionId,
                reason: reason,
                idempotencyKey: idempotencyKey.rawValue
            ),
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    func clear(sessionId: String, reason: String) async throws -> ContextControlResponseDTO {
        _ = try requireTransport().requireConnection()
        let idempotencyKey = EngineIdempotencyKey.userAction("contextControl.clear")
        return try await invokeWrite(
            "context_control::ui_clear",
            ContextControlActionRequestDTO(
                sessionId: sessionId,
                reason: reason,
                idempotencyKey: idempotencyKey.rawValue
            ),
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    func actionList(sessionId: String, limit: Int = 20) async throws -> ContextControlResponseDTO {
        _ = try requireTransport().requireConnection()
        return try await invokeRead(
            "context_control::ui_action_list",
            ContextControlActionListRequestDTO(sessionId: sessionId, limit: limit),
            context: sessionInvocationContext(sessionId)
        )
    }

    func actionInspect(
        sessionId: String,
        actionResourceId: String
    ) async throws -> ContextControlResponseDTO {
        _ = try requireTransport().requireConnection()
        return try await invokeRead(
            "context_control::ui_action_inspect",
            ContextControlActionInspectRequestDTO(
                sessionId: sessionId,
                contextControlActionResourceId: actionResourceId
            ),
            context: sessionInvocationContext(sessionId)
        )
    }
}
