import Foundation

/// Client for context management RPC methods.
/// Handles context snapshots, clearing, and compaction.
@MainActor
final class ContextClient {
    private unowned let transport: RPCTransport

    init(transport: RPCTransport) {
        self.transport = transport
    }

    // MARK: - Context Methods

    /// Get context snapshot for a session
    func getSnapshot(sessionId: String) async throws -> ContextSnapshotResult {
        let ws = try transport.requireConnection()

        let params = ContextGetSnapshotParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.getSnapshot",
            params: params
        )
    }

    /// Get detailed context snapshot with per-message token breakdown
    func getDetailedSnapshot(sessionId: String) async throws -> DetailedContextSnapshotResult {
        let ws = try transport.requireConnection()

        let params = ContextGetSnapshotParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.getDetailedSnapshot",
            params: params
        )
    }

    /// Clear all messages from context, preserving system prompt and tools
    func clear(sessionId: String) async throws -> ContextClearResult {
        let ws = try transport.requireConnection()

        let params = ContextClearParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.clear",
            params: params
        )
    }

    /// Compact context by summarizing older messages
    func compact(sessionId: String) async throws -> ContextCompactResult {
        let ws = try transport.requireConnection()

        let params = ContextCompactParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.compact",
            params: params,
            timeout: 60.0  // Compaction can take a while
        )
    }
}
