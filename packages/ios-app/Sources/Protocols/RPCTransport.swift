import Foundation

/// Interface that domain clients use to access the transport layer.
/// This protocol abstracts the WebSocket connection details from domain-specific clients.
@MainActor
protocol RPCTransport: AnyObject {
    /// The underlying WebSocket service for sending RPC calls
    var webSocket: WebSocketService? { get }

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
    /// Get the WebSocket service, throwing if not connected.
    /// Use this to replace: `guard let ws = transport.webSocket else { throw ... }`
    ///
    /// - Throws: `RPCClientError.connectionNotEstablished` if webSocket is nil
    /// - Returns: The active WebSocketService
    func requireConnection() throws -> WebSocketService {
        guard let ws = webSocket else {
            throw RPCClientError.connectionNotEstablished
        }
        return ws
    }

    /// Get the WebSocket service and current session ID, throwing if either is unavailable.
    /// Use this to replace: `guard let ws = ..., let sessionId = ... else { throw ... }`
    ///
    /// - Throws: `RPCClientError.noActiveSession` if webSocket or sessionId is nil
    /// - Returns: Tuple of (WebSocketService, sessionId)
    func requireSession() throws -> (WebSocketService, String) {
        guard let ws = webSocket, let sessionId = currentSessionId else {
            throw RPCClientError.noActiveSession
        }
        return (ws, sessionId)
    }
}
