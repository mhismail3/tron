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

    func create(workingDirectory: String, model: String? = nil) async throws -> SessionCreateResult {
        try await sessionClient.create(workingDirectory: workingDirectory, model: model)
    }

    func list(workingDirectory: String? = nil, limit: Int = 50, offset: Int = 0, includeArchived: Bool = false) async throws -> SessionListResult {
        try await sessionClient.list(workingDirectory: workingDirectory, limit: limit, offset: offset, includeArchived: includeArchived)
    }

    func resume(sessionId: String) async throws {
        try await sessionClient.resume(sessionId: sessionId)
    }

    func archive(sessionId: String) async throws {
        try await sessionClient.archive(sessionId)
    }

    func unarchive(sessionId: String) async throws {
        try await sessionClient.unarchive(sessionId)
    }

    func delete(sessionId: String) async throws -> Bool {
        try await sessionClient.delete(sessionId)
    }

    func fork(sessionId: String, fromEventId: String? = nil) async throws -> SessionForkResult {
        try await sessionClient.fork(sessionId, fromEventId: fromEventId)
    }

    func getHistory(limit: Int = 100) async throws -> [HistoryMessage] {
        try await sessionClient.getHistory(limit: limit)
    }
}
