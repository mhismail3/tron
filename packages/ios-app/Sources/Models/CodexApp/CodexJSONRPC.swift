import Foundation

enum CodexJSONRPCID: Codable, Hashable, Sendable, CustomStringConvertible {
    case string(String)
    case int(Int)

    var description: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        }
    }
}

struct CodexJSONRPCRequest: Encodable, Sendable {
    let id: CodexJSONRPCID
    let method: String
    let params: [String: AnyCodable]?

    init(id: CodexJSONRPCID, method: String, params: [String: AnyCodable]? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

struct CodexJSONRPCNotification: Codable, Equatable, Sendable {
    let method: String
    let params: [String: AnyCodable]?
}

struct CodexJSONRPCResponse: Decodable, Equatable, Sendable {
    let id: CodexJSONRPCID
    let result: [String: AnyCodable]?
    let error: CodexJSONRPCError?
}

struct CodexJSONRPCServerRequest: Decodable, Equatable, Sendable {
    let id: CodexJSONRPCID
    let method: String
    let params: [String: AnyCodable]?
}

struct CodexJSONRPCServerResponse: Encodable, Equatable, Sendable {
    let id: CodexJSONRPCID
    let result: [String: AnyCodable]?
    let error: CodexJSONRPCError?

    init(id: CodexJSONRPCID, result: [String: AnyCodable]) {
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: CodexJSONRPCID, error: CodexJSONRPCError) {
        self.id = id
        self.result = nil
        self.error = error
    }
}

struct CodexJSONRPCError: Codable, Equatable, Error, LocalizedError, Sendable {
    let code: Int
    let message: String
    let data: AnyCodable?

    init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    var errorDescription: String? { message }
}

enum CodexInboundMessage: Equatable, Sendable {
    case response(CodexJSONRPCResponse)
    case notification(CodexJSONRPCNotification)
    case serverRequest(CodexJSONRPCServerRequest)

    static func decode(_ data: Data) throws -> CodexInboundMessage {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw CodexTransportError.invalidMessage("Expected JSON object")
        }

        let decoder = JSONDecoder()
        let hasID = dict["id"] != nil
        let hasMethod = dict["method"] != nil

        switch (hasID, hasMethod) {
        case (true, true):
            return .serverRequest(try decoder.decode(CodexJSONRPCServerRequest.self, from: data))
        case (true, false):
            return .response(try decoder.decode(CodexJSONRPCResponse.self, from: data))
        case (false, true):
            return .notification(try decoder.decode(CodexJSONRPCNotification.self, from: data))
        case (false, false):
            throw CodexTransportError.invalidMessage("Message had neither id nor method")
        }
    }
}

enum CodexTransportError: Error, Equatable, LocalizedError {
    case notConnected
    case timeout
    case invalidMessage(String)
    case requestFailed(String)
    case unauthorized(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Codex App Server is not connected."
        case .timeout: "Codex App Server request timed out."
        case .invalidMessage(let reason): "Invalid Codex App Server message: \(reason)"
        case .requestFailed(let reason): reason
        case .unauthorized(let reason): "Codex App Server rejected authentication: \(reason)"
        }
    }
}

extension Encodable {
    func codexParams() throws -> [String: AnyCodable] {
        let data = try JSONEncoder().encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.mapValues { AnyCodable($0) }
    }
}
