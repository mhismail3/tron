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
