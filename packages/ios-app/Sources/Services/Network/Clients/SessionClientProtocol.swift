import Foundation

/// Protocol for session client operations.
/// Enables dependency injection for testing session management.
@MainActor
protocol SessionClientProtocol {
    func create(
        workingDirectory: String,
        model: String?
    ) async throws -> SessionCreateResult

    func list(
        workingDirectory: String?,
        limit: Int,
        offset: Int,
        includeArchived: Bool
    ) async throws -> SessionListResult

    func resume(sessionId: String) async throws

    func archive(_ sessionId: String) async throws

    func unarchive(_ sessionId: String) async throws

    func getHistory(limit: Int) async throws -> [HistoryMessage]

    func delete(_ sessionId: String) async throws -> Bool

    func fork(_ sessionId: String, fromEventId: String?) async throws -> SessionForkResult
}

// MARK: - Default Parameter Extensions

extension SessionClientProtocol {
    func create(
        workingDirectory: String,
        model: String? = nil
    ) async throws -> SessionCreateResult {
        try await create(workingDirectory: workingDirectory, model: model)
    }

    func list(
        workingDirectory: String? = nil,
        limit: Int = 50,
        offset: Int = 0,
        includeArchived: Bool = false
    ) async throws -> SessionListResult {
        try await list(workingDirectory: workingDirectory, limit: limit, offset: offset, includeArchived: includeArchived)
    }

    func getHistory(limit: Int = 100) async throws -> [HistoryMessage] {
        try await getHistory(limit: limit)
    }

    func fork(_ sessionId: String, fromEventId: String? = nil) async throws -> SessionForkResult {
        try await fork(sessionId, fromEventId: fromEventId)
    }
}

// MARK: - SessionClient Conformance

extension SessionClient: SessionClientProtocol {}
