import Foundation

/// Client for context management RPC methods.
/// Handles context snapshots, clearing, and compaction.
@MainActor
final class ContextClient {
    private weak var transport: RPCTransport?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    // MARK: - Context Methods

    /// Get context snapshot for a session
    func getSnapshot(sessionId: String) async throws -> ContextSnapshotResult {
        guard let transport = transport, let ws = transport.webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = ContextGetSnapshotParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.getSnapshot",
            params: params
        )
    }

    /// Get detailed context snapshot with per-message token breakdown
    func getDetailedSnapshot(sessionId: String) async throws -> DetailedContextSnapshotResult {
        guard let transport = transport, let ws = transport.webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = ContextGetSnapshotParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.getDetailedSnapshot",
            params: params
        )
    }

    /// Clear all messages from context, preserving system prompt and tools
    func clear(sessionId: String) async throws -> ContextClearResult {
        guard let transport = transport, let ws = transport.webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = ContextClearParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.clear",
            params: params
        )
    }

    /// Compact context by summarizing older messages
    func compact(sessionId: String) async throws -> ContextCompactResult {
        guard let transport = transport, let ws = transport.webSocket else {
            throw RPCClientError.connectionNotEstablished
        }

        let params = ContextCompactParams(sessionId: sessionId)
        return try await ws.send(
            method: "context.compact",
            params: params,
            timeout: 60.0  // Compaction can take a while
        )
    }
}
