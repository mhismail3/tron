import Foundation

// MARK: - Session Repository Protocol

/// Repository protocol for session operations.
/// Provides abstraction over SessionClient for network session management.
@MainActor
protocol NetworkSessionRepository: AnyObject {
    /// Create a new session.
    /// - Parameters:
    ///   - workingDirectory: The working directory for the session
    ///   - model: Optional model to use for the session
    /// - Returns: Result of session creation
    func create(workingDirectory: String, model: String?) async throws -> SessionCreateResult

    /// List available sessions.
    /// - Parameters:
    ///   - workingDirectory: Optional filter by working directory
    ///   - limit: Maximum number of sessions to return
    ///   - offset: Offset for pagination
    ///   - includeArchived: Whether to include archived sessions
    /// - Returns: Session list result with pagination info
    func list(workingDirectory: String?, limit: Int, offset: Int, includeArchived: Bool) async throws -> SessionListResult

    /// Resume an existing session.
    /// - Parameter sessionId: The session ID to resume
    func resume(sessionId: String) async throws

    /// Archive a session.
    /// - Parameter sessionId: The session ID to archive
    func archive(sessionId: String) async throws

    /// Unarchive a session.
    /// - Parameter sessionId: The session ID to unarchive
    func unarchive(sessionId: String) async throws

    /// Delete a session (archives on server).
    /// - Parameter sessionId: The session ID to delete
    /// - Returns: Whether the session was deleted
    func delete(sessionId: String) async throws -> Bool

    /// Fork a session from a specific point.
    /// - Parameters:
    ///   - sessionId: The session to fork
    ///   - fromEventId: Optional event ID to fork from
    /// - Returns: Result of the fork operation
    func fork(sessionId: String, fromEventId: String?) async throws -> SessionForkResult

    /// Get session history.
    /// - Parameter limit: Maximum number of messages to return
    /// - Returns: Array of history messages
    func getHistory(limit: Int) async throws -> [HistoryMessage]
}
