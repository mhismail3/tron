import Foundation

// MARK: - JSON-RPC Base Types

/// JSON-RPC 2.0 style request wrapper
struct RPCRequest<P: Encodable>: Encodable {
    let id: String
    let method: String
    let params: P

    init(method: String, params: P) {
        self.id = UUID().uuidString
        self.method = method
        self.params = params
    }
}

/// JSON-RPC response wrapper
struct RPCResponse<R: Decodable>: Decodable {
    let id: String
    let success: Bool
    let result: R?
    let error: RPCError?
}

/// Known RPC error codes from the server
enum RPCErrorCode: String, Sendable {
    case sessionNotFound = "SESSION_NOT_FOUND"
    case agentNotRunning = "AGENT_NOT_RUNNING"
    case invalidParams = "INVALID_PARAMS"
    case methodNotFound = "METHOD_NOT_FOUND"
    case internalError = "INTERNAL_ERROR"
}

/// RPC error details
struct RPCError: Decodable, Error, LocalizedError, Sendable {
    let code: String
    let message: String
    let details: [String: AnyCodable]?

    var errorDescription: String? { message }

    /// Typed error code (nil for unknown codes)
    var errorCode: RPCErrorCode? { RPCErrorCode(rawValue: code) }
}

/// Empty params for methods that don't require parameters
struct EmptyParams: Codable {}
