import Foundation

struct GatewayInfo: Codable, Hashable, Sendable {
    let gatewayVersion: String
    let piVersion: String
    let protocolVersion: Int
    let minProtocolVersion: Int
    let machineId: String
    let machineName: String
    let capabilities: [String]
}

struct PairedDevice: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let createdAt: String
}
