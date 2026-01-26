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

/// RPC error details
struct RPCError: Decodable, Error, LocalizedError, Sendable {
    let code: String
    let message: String
    let details: [String: AnyCodable]?

    var errorDescription: String? { message }
}

/// Empty params for methods that don't require parameters
struct EmptyParams: Codable {}
