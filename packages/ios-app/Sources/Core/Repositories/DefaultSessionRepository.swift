import Foundation

// MARK: - Default Session Repository

/// Default implementation of NetworkSessionRepository.
/// Wraps SessionClient for network session operations.
@MainActor
final class DefaultSessionRepository: NetworkSessionRepository {
    private let sessionClient: SessionClient

    // MARK: - Initialization

    init(sessionClient: SessionClient) {
        self.sessionClient = sessionClient
    }

    // MARK: - NetworkSessionRepository

    func create(
        workingDirectory: String,
        model: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> SessionCreateResult {
        try await sessionClient.create(
            workingDirectory: workingDirectory,
            model: model,
            idempotencyKey: idempotencyKey
        )
    }

    func list(workingDirectory: String? = nil, limit: Int = 50, offset: Int = 0, includeArchived: Bool = false) async throws -> SessionListResult {
        try await sessionClient.list(workingDirectory: workingDirectory, limit: limit, offset: offset, includeArchived: includeArchived)
    }

    func resume(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {
        try await sessionClient.resume(sessionId: sessionId, idempotencyKey: idempotencyKey)
    }

    func archive(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {
        try await sessionClient.archive(sessionId, idempotencyKey: idempotencyKey)
    }

    func unarchive(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws {
        try await sessionClient.unarchive(sessionId, idempotencyKey: idempotencyKey)
    }

    func fork(
        sessionId: String,
        fromEventId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> SessionForkResult {
        try await sessionClient.fork(
            sessionId,
            fromEventId: fromEventId,
            idempotencyKey: idempotencyKey
        )
    }

    func getHistory(limit: Int = 100) async throws -> [HistoryMessage] {
        try await sessionClient.getHistory(limit: limit)
    }
}
