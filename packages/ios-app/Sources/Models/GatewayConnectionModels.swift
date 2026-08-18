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
