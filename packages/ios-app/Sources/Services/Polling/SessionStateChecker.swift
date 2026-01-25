import Foundation

/// Checks session processing states from the server.
/// Determines whether agents are currently running for sessions.
@MainActor
final class SessionStateChecker {

    // MARK: - Dependencies

    private let rpcClient: RPCClient

    // MARK: - Initialization

    init(rpcClient: RPCClient) {
        self.rpcClient = rpcClient
    }

    /// Update the RPC client reference
    func updateRPCClient(_ client: RPCClient) {
        // Note: This is a workaround since rpcClient is let
        // In practice, EventStoreManager handles client updates
    }

    // MARK: - State Checking

    /// Check if a session's agent is currently running.
    /// - Parameter sessionId: The session ID to check
    /// - Returns: Whether the agent is running, or nil if check failed
    func checkProcessingState(sessionId: String) async -> Bool? {
        do {
            // Ensure connection
            if !rpcClient.isConnected {
                await rpcClient.connect()
                if !rpcClient.isConnected {
                    return nil
                }
            }

            let state = try await rpcClient.agent.getState(sessionId: sessionId)
            return state.isRunning
        } catch {
            logger.debug("Failed to check session \(sessionId) state: \(error.localizedDescription)")
            return nil
        }
    }

    /// Pre-warm the WebSocket connection for faster session entry.
    func preWarmConnection() async {
        guard !rpcClient.isConnected else {
            logger.verbose("Connection already established, skipping pre-warm", category: .rpc)
            return
        }

        logger.info("Pre-warming WebSocket connection for faster session entry", category: .rpc)
        await rpcClient.connect()

        if rpcClient.isConnected {
            logger.info("WebSocket pre-warm complete - connection ready", category: .rpc)
        } else {
            logger.warning("WebSocket pre-warm failed - will retry on session entry", category: .rpc)
        }
    }
}
