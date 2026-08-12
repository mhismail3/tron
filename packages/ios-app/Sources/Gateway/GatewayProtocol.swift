import Foundation

struct GatewayRequest: Encodable, Sendable {
    let type = "request"
    let id: String
    let method: String
    let params: JSONValue
}

struct GatewayResponse: Decodable, Sendable {
    let type: String
    let id: String
    let ok: Bool
    let result: JSONValue?
    let error: GatewayFailure?
}

struct GatewayFailure: Codable, Error, Hashable, Sendable, LocalizedError {
    let code: String
    let message: String
    let retryable: Bool
    let details: JSONValue?

    var errorDescription: String? { message }
}

struct GatewayEvent: Decodable, Sendable {
    let type: String
    let topic: String
    let sessionId: String?
    let payload: JSONValue
}

struct GatewayHello: Decodable, Sendable {
    let type: String
    let gatewayVersion: String
    let piVersion: String
    let protocolVersion: Int
    let minProtocolVersion: Int
    let machineId: String
    let machineName: String
    let capabilities: [String]

    var info: GatewayInfo {
        GatewayInfo(
            gatewayVersion: gatewayVersion,
            piVersion: piVersion,
            protocolVersion: protocolVersion,
            minProtocolVersion: minProtocolVersion,
            machineId: machineId,
            machineName: machineName,
            capabilities: capabilities
        )
    }
}

struct EmptyParams: Codable, Sendable {}

struct CommandParams: Codable, Sendable {
    let commandId: String
    init(commandId: String = UUID().uuidString) { self.commandId = commandId }
}
