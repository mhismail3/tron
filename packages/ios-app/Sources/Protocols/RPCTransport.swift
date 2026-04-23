import Foundation

/// Interface that domain clients use to access the transport layer.
/// This protocol abstracts the WebSocket connection details from domain-specific clients.
@MainActor
protocol RPCTransport: AnyObject {
    /// The underlying WebSocket service for sending RPC calls
    var webSocket: WebSocketService? { get }

    /// Aggregated connection state. Usually mirrors `webSocket.connectionState` but is
    /// exposed at the transport level so the fail-fast guard does not depend on digging
    /// into the concrete `WebSocketService`.
    var connectionState: ConnectionState { get }

    /// Current active session ID, if any
    var currentSessionId: String? { get }

    /// Current model being used
    var currentModel: String { get }

    /// Server origin string (host:port) for tagging sessions
    var serverOrigin: String { get }

    /// Update the current session ID
    func setCurrentSessionId(_ id: String?)

    /// Update the current model
    func setCurrentModel(_ model: String)
}

// MARK: - Connection Helpers

extension RPCTransport {
    /// Get the WebSocket service, throwing if the transport is not ready for RPCs.
    ///
    /// Fail-fast: if the connection is not `.connected`, throws
    /// `WebSocketError.notConnected` immediately rather than letting the domain-client
    /// call proceed into a 30-second request timeout.
    ///
    /// - Throws: `RPCClientError.connectionNotEstablished` if webSocket is nil,
    ///           `WebSocketError.notConnected` if connectionState is not connected.
    /// - Returns: The active WebSocketService.
    func requireConnection() throws -> WebSocketService {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }
        guard connectionState.isConnected else {
            throw WebSocketError.notConnected
        }
        return ws
    }

    /// Get the WebSocket service and current session ID, throwing if either is unavailable.
    ///
    /// Fail-fast: mirrors `requireConnection` for the connection-state guard.
    ///
    /// - Throws: `RPCClientError.noActiveSession` if webSocket or sessionId is nil,
    ///           `WebSocketError.notConnected` if connectionState is not connected.
    /// - Returns: Tuple of (WebSocketService, sessionId)
    func requireSession() throws -> (WebSocketService, String) {
        guard let ws = webSocket, let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }
        guard connectionState.isConnected else {
            throw WebSocketError.notConnected
        }
        return (ws, sessionId)
    }
}
