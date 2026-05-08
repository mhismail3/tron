import Foundation

/// Client for context management engine capabilities.
/// Handles context snapshots, clearing, and compaction.
final class ContextClient: EngineDomainClient {

    // MARK: - Context Methods

    /// Get context snapshot for a session
    func getSnapshot(sessionId: String) async throws -> ContextSnapshotResult {
        _ = try requireTransport().requireConnection()

        let params = ContextGetSnapshotParams(sessionId: sessionId)
        return try await invokeRead(
            "context::get_snapshot",
            params
        )
    }

    /// Get detailed context snapshot with per-message token breakdown
    func getDetailedSnapshot(sessionId: String) async throws -> DetailedContextSnapshotResult {
        _ = try requireTransport().requireConnection()

        let params = ContextGetSnapshotParams(sessionId: sessionId)
        return try await invokeRead(
            "context::get_detailed_snapshot",
            params
        )
    }

    /// Clear all messages from context, preserving system prompt and tools
    func clear(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws -> ContextClearResult {
        _ = try requireTransport().requireConnection()

        let params = ContextClearParams(sessionId: sessionId)
        return try await invokeWrite(
            "context::clear",
            params,
            idempotencyKey: idempotencyKey
        )
    }

    /// Compact context by summarizing older messages
    func compact(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws -> ContextCompactResult {
        _ = try requireTransport().requireConnection()

        let params = ContextCompactParams(sessionId: sessionId)
        return try await invokeWrite(
            "context::compact",
            params,
            idempotencyKey: idempotencyKey,
            timeout: 60.0
        )
    }
}
