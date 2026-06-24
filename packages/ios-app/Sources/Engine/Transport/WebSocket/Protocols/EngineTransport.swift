import Foundation

/// Interface that domain clients use to access the transport layer.
/// This protocol abstracts the engine WebSocket connection details from domain-specific clients.
@MainActor
protocol EngineTransport: AnyObject {
    /// The underlying engine connection.
    var engineConnection: EngineConnection? { get }

    /// Aggregated connection state. Usually mirrors `engineConnection.connectionState` but is
    /// exposed at the transport level so the fail-fast guard does not depend on digging
    /// into the concrete `EngineConnection`.
    var connectionState: ConnectionState { get }

    /// Current active session ID, if any
    var currentSessionId: String? { get }

    /// Current model being used
    var currentModel: String { get }

    /// Server origin string (host:port) for tagging sessions
    var serverOrigin: String { get }

    /// Update the current session ID
    func setCurrentSessionId(_ id: String?)

    /// Ensure the transport has an active engine stream subscription for the
    /// session before server-owned work can publish live events.
    @discardableResult
    func ensureSessionEventSubscription(sessionId: String, workspaceId: String?) async throws -> EngineSubscription

    /// Update the current model
    func setCurrentModel(_ model: String)

    func invokeRead<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        options: EngineInvocationOptions
    ) async throws -> R

    func invokeWrite<P: Encodable, R: Decodable>(
        functionId: EngineFunctionId,
        payload: P,
        idempotencyKey: EngineIdempotencyKey,
        options: EngineInvocationOptions
    ) async throws -> R
}

// MARK: - Connection Helpers

extension EngineTransport {
    /// Get the engine connection, throwing if the transport is not ready.
    ///
    /// Fail-fast: if the connection is not `.connected`, throws
    /// `EngineConnectionError.notConnected` immediately rather than letting the domain-client
    /// call proceed into a 30-second request timeout.
    ///
    /// - Throws: `EngineClientError.connectionNotEstablished` if engineConnection is nil,
    ///           `EngineConnectionError.notConnected` if connectionState is not connected.
    /// - Returns: The active EngineConnection.
    func requireConnection() throws -> EngineConnection {
        guard let ws = engineConnection else {
            throw EngineClientError.connectionNotEstablished
        }
        guard connectionState.isConnected else {
            throw EngineConnectionError.notConnected
        }
        return ws
    }

    /// Get the engine connection and current session ID, throwing if either is unavailable.
    ///
    /// Fail-fast: mirrors `requireConnection` for the connection-state guard.
    ///
    /// - Throws: `EngineClientError.noActiveSession` if engineConnection or sessionId is nil,
    ///           `EngineConnectionError.notConnected` if connectionState is not connected.
    /// - Returns: Tuple of (EngineConnection, sessionId)
    func requireSession() throws -> (EngineConnection, String) {
        guard let ws = engineConnection, let sessionId = currentSessionId else {
            throw EngineClientError.noActiveSession
        }
        guard connectionState.isConnected else {
            throw EngineConnectionError.notConnected
        }
        return (ws, sessionId)
    }
}
