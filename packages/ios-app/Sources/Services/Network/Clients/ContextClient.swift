import Foundation

/// Client for context management RPC methods.
/// Handles context snapshots, clearing, and compaction.
@MainActor
final class ContextClient {
    private weak var transport: (any RPCTransport)?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    /// Access transport safely, throwing if deallocated during server change.
    private func requireTransport() throws -> any RPCTransport {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        return transport
    }

    // MARK: - Context Methods

    /// Get context snapshot for a session
    func getSnapshot(sessionId: String) async throws -> ContextSnapshotResult {
        let ws = try requireTransport().requireConnection()

        let params = ContextGetSnapshotParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.getSnapshot",
            params: params
        )
    }

    /// Get detailed context snapshot with per-message token breakdown
    func getDetailedSnapshot(sessionId: String) async throws -> DetailedContextSnapshotResult {
        let ws = try requireTransport().requireConnection()

        let params = ContextGetSnapshotParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.getDetailedSnapshot",
            params: params
        )
    }

    /// Clear all messages from context, preserving system prompt and tools
    func clear(sessionId: String) async throws -> ContextClearResult {
        let ws = try requireTransport().requireConnection()

        let params = ContextClearParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.clear",
            params: params
        )
    }

    /// Compact context by summarizing older messages
    func compact(sessionId: String) async throws -> ContextCompactResult {
        let ws = try requireTransport().requireConnection()

        let params = ContextCompactParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.compact",
            params: params,
            timeout: 60.0  // Compaction can take a while
        )
    }
}
