import Foundation

struct GatewayInfo: Codable, Hashable, Sendable {
    let gatewayVersion: String
    let piVersion: String
    let protocolVersion: Int
    let minProtocolVersion: Int
    let machineId: String
    let machineGroupID: String
    let machineName: String
    let capabilities: [String]

    init(gatewayVersion: String, piVersion: String, protocolVersion: Int, minProtocolVersion: Int,
         machineId: String, machineGroupID: String? = nil, machineName: String, capabilities: [String]) {
        self.gatewayVersion = gatewayVersion
        self.piVersion = piVersion
        self.protocolVersion = protocolVersion
        self.minProtocolVersion = minProtocolVersion
        self.machineId = machineId
        self.machineGroupID = machineGroupID ?? machineId
        self.machineName = machineName
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey { case gatewayVersion, piVersion, protocolVersion, minProtocolVersion, machineId, machineGroupID, machineName, capabilities }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            gatewayVersion: try values.decode(String.self, forKey: .gatewayVersion),
            piVersion: try values.decode(String.self, forKey: .piVersion),
            protocolVersion: try values.decode(Int.self, forKey: .protocolVersion),
            minProtocolVersion: try values.decode(Int.self, forKey: .minProtocolVersion),
            machineId: try values.decode(String.self, forKey: .machineId),
            machineGroupID: try values.decodeIfPresent(String.self, forKey: .machineGroupID),
            machineName: try values.decode(String.self, forKey: .machineName),
            capabilities: try values.decode([String].self, forKey: .capabilities)
        )
    }
}

struct PairedDevice: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let createdAt: String
}

struct GatewayAuthorizedDevice: Hashable, Identifiable, Sendable {
    let profileID: String
    let profileLabel: String
    let device: PairedDevice

    var id: String { "\(profileID):\(device.id)" }
}


enum PairedDeviceCatalogPolicy {
    static let maximumDevices = 256
    static let maximumIDBytes = 100
    static let maximumNameBytes = 320
    static let maximumTimestampBytes = 64

    static func admit(_ devices: [PairedDevice]) throws -> [PairedDevice] {
        guard devices.count <= maximumDevices else { throw invalidCatalog() }
        var identities = Set<String>()
        identities.reserveCapacity(devices.count)
        for device in devices {
            guard !device.id.isEmpty,
                  device.id.utf8.count <= maximumIDBytes,
                  !device.name.isEmpty,
                  device.name.utf8.count <= maximumNameBytes,
                  device.name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !device.createdAt.isEmpty,
                  device.createdAt.utf8.count <= maximumTimestampBytes,
                  GatewayTimestamp.parse(device.createdAt) != nil,
                  identities.insert(device.id).inserted else {
                throw invalidCatalog()
            }
        }
        return devices
    }

    private static func invalidCatalog() -> GatewayFailure {
        GatewayFailure(
            code: "invalid_response",
            message: "The paired-device list from the Mac is invalid or too large.",
            retryable: true,
            details: nil
        )
    }
}
