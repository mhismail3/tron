import Foundation

struct GatewayRuntimeIdentity: Codable, Hashable, Sendable {
    let sourceRevision: String?
    let buildFingerprint: String?
    let runtimeEpoch: String?
}

struct GatewayUpdateIdentity: Codable, Hashable, Sendable {
    let version: String?
    let gatewayVersion: String?
    let sourceRevision: String?
    let runtimeEpoch: String?
    let payloadFingerprint: String?
}

enum GatewayUpdateConfigPolicy {
    static let maximumPathBytes = 4_096
    static let maximumTimestampBytes = 64

    static func admitPath(_ path: String, name: String) throws -> String {
        guard !path.isEmpty,
              path.utf8.count <= maximumPathBytes,
              path.first == "/",
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw GatewayFailure(
                code: "invalid_response",
                message: "The Gateway update configuration contains an invalid \(name) path.",
                retryable: true,
                details: nil
            )
        }
        return path
    }

    static func admitTimestamp(_ timestamp: String) throws -> String {
        guard !timestamp.isEmpty,
              timestamp.utf8.count <= maximumTimestampBytes,
              GatewayTimestamp.parse(timestamp) != nil else {
            throw GatewayFailure(
                code: "invalid_response",
                message: "The Gateway update configuration has an invalid timestamp.",
                retryable: true,
                details: nil
            )
        }
        return timestamp
    }
}

struct GatewayUpdateConfig: Codable, Hashable, Sendable {
    let schema: Int
    let kind: String
    let sourceRoot: String
    let artifactRoot: String?
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case schema, kind, sourceRoot, artifactRoot, updatedAt
    }

    init(schema: Int = 1, kind: String = "tron-gateway-update-config", sourceRoot: String, artifactRoot: String? = nil, updatedAt: String) throws {
        guard schema == 1, kind == "tron-gateway-update-config" else {
            throw GatewayFailure(code: "invalid_response", message: "The Gateway update configuration is unsupported.", retryable: true, details: nil)
        }
        self.schema = schema
        self.kind = kind
        self.sourceRoot = try GatewayUpdateConfigPolicy.admitPath(sourceRoot, name: "source repository")
        if let artifactRoot {
            self.artifactRoot = try GatewayUpdateConfigPolicy.admitPath(artifactRoot, name: "artifact root")
        } else {
            self.artifactRoot = nil
        }
        self.updatedAt = try GatewayUpdateConfigPolicy.admitTimestamp(updatedAt)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self = try Self(
            schema: try values.decode(Int.self, forKey: .schema),
            kind: try values.decode(String.self, forKey: .kind),
            sourceRoot: try values.decode(String.self, forKey: .sourceRoot),
            artifactRoot: try values.decodeIfPresent(String.self, forKey: .artifactRoot),
            updatedAt: try values.decode(String.self, forKey: .updatedAt)
        )
    }
}

struct GatewayUpdateStatus: Codable, Hashable, Sendable {
    let state: String
    let channel: String
    let currentIdentity: GatewayUpdateIdentity?
    let candidateIdentity: GatewayUpdateIdentity?
    let candidateAvailable: Bool
    let error: String?
    let updatedAt: String?
    let commandId: String?
    let rollbackAvailable: Bool

    init(
        state: String, channel: String, currentIdentity: GatewayUpdateIdentity?,
        candidateIdentity: GatewayUpdateIdentity?, candidateAvailable: Bool,
        error: String?, updatedAt: String?, commandId: String? = nil,
        rollbackAvailable: Bool = false
    ) {
        self.state = state
        self.channel = channel
        self.currentIdentity = currentIdentity
        self.candidateIdentity = candidateIdentity
        self.candidateAvailable = candidateAvailable
        self.error = error
        self.updatedAt = updatedAt
        self.commandId = commandId
        self.rollbackAvailable = rollbackAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case state, channel, currentIdentity, candidateIdentity, candidateAvailable, error, updatedAt, commandId, rollbackAvailable
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            state: try values.decode(String.self, forKey: .state),
            channel: try values.decode(String.self, forKey: .channel),
            currentIdentity: try values.decodeIfPresent(GatewayUpdateIdentity.self, forKey: .currentIdentity),
            candidateIdentity: try values.decodeIfPresent(GatewayUpdateIdentity.self, forKey: .candidateIdentity),
            candidateAvailable: try values.decode(Bool.self, forKey: .candidateAvailable),
            error: try values.decodeIfPresent(String.self, forKey: .error),
            updatedAt: try values.decodeIfPresent(String.self, forKey: .updatedAt),
            commandId: try values.decodeIfPresent(String.self, forKey: .commandId),
            rollbackAvailable: try values.decodeIfPresent(Bool.self, forKey: .rollbackAvailable) ?? false
        )
    }

    var presentationTitle: String {
        switch state {
        case "failed", "failure": return "Update failed"
        case "rolled-back": return "Rolled back"
        case "ready": return "Ready"
        case "starting", "building", "staging", "promoting", "restart", "rollback", "rollback-requested":
            return state.replacingOccurrences(of: "-", with: " ").capitalized
        case "unknown": return "Unavailable"
        default: return candidateAvailable ? "Update available" : state.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

struct GatewayInfo: Codable, Hashable, Sendable {
    let gatewayVersion: String
    let piVersion: String
    let protocolVersion: Int
    let minProtocolVersion: Int
    let machineId: String
    let machineGroupID: String
    let machineName: String
    let capabilities: [String]
    let sourceRevision: String?
    let buildFingerprint: String?
    let runtimeEpoch: String?

    init(gatewayVersion: String, piVersion: String, protocolVersion: Int, minProtocolVersion: Int,
         machineId: String, machineGroupID: String? = nil, machineName: String, capabilities: [String],
         sourceRevision: String? = nil, buildFingerprint: String? = nil, runtimeEpoch: String? = nil) {
        self.gatewayVersion = gatewayVersion
        self.piVersion = piVersion
        self.protocolVersion = protocolVersion
        self.minProtocolVersion = minProtocolVersion
        self.machineId = machineId
        self.machineGroupID = machineGroupID ?? machineId
        self.machineName = machineName
        self.capabilities = capabilities
        self.sourceRevision = sourceRevision
        self.buildFingerprint = buildFingerprint
        self.runtimeEpoch = runtimeEpoch
    }

    private enum CodingKeys: String, CodingKey { case gatewayVersion, piVersion, protocolVersion, minProtocolVersion, machineId, machineGroupID, machineName, capabilities, sourceRevision, buildFingerprint, runtimeEpoch }

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
            capabilities: try values.decode([String].self, forKey: .capabilities),
            sourceRevision: try values.decodeIfPresent(String.self, forKey: .sourceRevision),
            buildFingerprint: try values.decodeIfPresent(String.self, forKey: .buildFingerprint),
            runtimeEpoch: try values.decodeIfPresent(String.self, forKey: .runtimeEpoch)
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
