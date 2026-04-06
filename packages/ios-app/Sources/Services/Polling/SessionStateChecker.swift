import Foundation

/// Checks session processing states from the server.
/// Determines whether agents are currently running for sessions.
@MainActor
final class SessionStateChecker {

    // MARK: - Dependencies

    private var rpcClient: RPCClient

    /// Consecutive failure counts per session for exponential backoff.
    private var consecutiveFailures: [String: Int] = [:]

    // MARK: - Initialization

    init(rpcClient: RPCClient) {
        self.rpcClient = rpcClient
    }

    /// Update the RPC client reference when server settings change.
    func updateRPCClient(_ client: RPCClient) {
        rpcClient = client
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
                    consecutiveFailures[sessionId, default: 0] += 1
                    return nil
                }
            }

            let result = try await rpcClient.session.reconstruct(sessionId: sessionId, limit: 0)
            consecutiveFailures.removeValue(forKey: sessionId)
            return result.isRunning
        } catch {
            logger.debug("Failed to check session \(sessionId) state: \(error.localizedDescription)")
            consecutiveFailures[sessionId, default: 0] += 1
            return nil
        }
    }

    /// Whether a session should be skipped this poll cycle due to repeated failures.
    /// Uses exponential backoff: after N consecutive failures, skip with probability 1 - 1/2^N (capped at 2^5=32).
    func shouldSkip(sessionId: String) -> Bool {
        guard let count = consecutiveFailures[sessionId], count > 0 else { return false }
        let exponent = min(count, 5) // cap at 2^5 = 32 cycle backoff
        return Int.random(in: 0..<(1 << exponent)) != 0
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
