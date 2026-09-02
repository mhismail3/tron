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

struct GatewayDebugCandidateProvenance: Codable, Hashable, Sendable {
    let origin: String
    let version: String
    let payloadFingerprint: String
    let sourceRevision: String
    let testedRuntimeEpoch: String
    let candidateRuntimeEpoch: String
}

struct GatewayDebugPromotionCandidate: Hashable, Sendable {
    let version: String
    let payloadFingerprint: String
    let sourceRevision: String
    let testedRuntimeEpoch: String
    let candidateRuntimeEpoch: String

    init?(identity: GatewayUpdateIdentity?, provenance: GatewayDebugCandidateProvenance?) {
        guard let identity, let provenance,
              provenance.origin == "debug",
              let version = identity.version,
              Self.validComponent(version),
              let payloadFingerprint = identity.payloadFingerprint,
              Self.validFingerprint(payloadFingerprint),
              let sourceRevision = identity.sourceRevision,
              Self.validSourceRevision(sourceRevision),
              let candidateRuntimeEpoch = identity.runtimeEpoch,
              Self.validComponent(candidateRuntimeEpoch),
              provenance.version == version,
              provenance.payloadFingerprint == payloadFingerprint,
              provenance.sourceRevision == sourceRevision,
              provenance.candidateRuntimeEpoch == candidateRuntimeEpoch,
              Self.validComponent(provenance.testedRuntimeEpoch) else { return nil }
        self.version = version
        self.payloadFingerprint = payloadFingerprint
        self.sourceRevision = sourceRevision
        self.testedRuntimeEpoch = provenance.testedRuntimeEpoch
        self.candidateRuntimeEpoch = candidateRuntimeEpoch
    }

    static func validComponent(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf8.count <= 128, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122)
                || $0 == "." || $0 == "_" || $0 == "-"
        }
    }

    static func validFingerprint(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }

    private static func validSourceRevision(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
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
    let candidateOrigin: String?
    let candidateProvenance: GatewayDebugCandidateProvenance?

    init(
        state: String, channel: String, currentIdentity: GatewayUpdateIdentity?,
        candidateIdentity: GatewayUpdateIdentity?, candidateAvailable: Bool,
        error: String?, updatedAt: String?, commandId: String? = nil,
        rollbackAvailable: Bool = false, candidateOrigin: String? = nil,
        candidateProvenance: GatewayDebugCandidateProvenance? = nil
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
        self.candidateOrigin = candidateOrigin
        self.candidateProvenance = candidateProvenance
    }

    private enum CodingKeys: String, CodingKey {
        case state, channel, currentIdentity, candidateIdentity, candidateAvailable, error, updatedAt, commandId, rollbackAvailable, candidateOrigin, candidateProvenance
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let candidateOrigin = try values.decodeIfPresent(String.self, forKey: .candidateOrigin)
        guard candidateOrigin == nil || candidateOrigin == "debug" else {
            throw GatewayFailure(code: "invalid_response", message: "The Gateway candidate origin is invalid.", retryable: true, details: nil)
        }
        let channel = try values.decode(String.self, forKey: .channel)
        let candidateIdentity = try values.decodeIfPresent(GatewayUpdateIdentity.self, forKey: .candidateIdentity)
        let candidateAvailable = try values.decode(Bool.self, forKey: .candidateAvailable)
        let candidateProvenance = try values.decodeIfPresent(GatewayDebugCandidateProvenance.self, forKey: .candidateProvenance)
        if candidateOrigin == "debug" {
            guard channel == "stable", candidateAvailable,
                  GatewayDebugPromotionCandidate(identity: candidateIdentity, provenance: candidateProvenance) != nil else {
                throw GatewayFailure(
                    code: "invalid_response",
                    message: "The tested Debug candidate provenance is incomplete or does not match its verified identity.",
                    retryable: true,
                    details: nil
                )
            }
        } else if candidateProvenance != nil {
            throw GatewayFailure(
                code: "invalid_response",
                message: "The Gateway candidate provenance has no admitted Debug origin.",
                retryable: true,
                details: nil
            )
        }
        self.init(
            state: try values.decode(String.self, forKey: .state),
            channel: channel,
            currentIdentity: try values.decodeIfPresent(GatewayUpdateIdentity.self, forKey: .currentIdentity),
            candidateIdentity: candidateIdentity,
            candidateAvailable: candidateAvailable,
            error: try values.decodeIfPresent(String.self, forKey: .error),
            updatedAt: try values.decodeIfPresent(String.self, forKey: .updatedAt),
            commandId: try values.decodeIfPresent(String.self, forKey: .commandId),
            rollbackAvailable: try values.decodeIfPresent(Bool.self, forKey: .rollbackAvailable) ?? false,
            candidateOrigin: candidateOrigin,
            candidateProvenance: candidateProvenance
        )
    }

    var debugPromotionCandidate: GatewayDebugPromotionCandidate? {
        guard candidateOrigin == "debug", channel == "stable", candidateAvailable else { return nil }
        return GatewayDebugPromotionCandidate(identity: candidateIdentity, provenance: candidateProvenance)
    }

    var isActive: Bool {
        ["starting", "building", "staging", "draining", "promoting", "restart", "rollback", "rollback-requested", "restart-requested"].contains(state)
    }

    var presentationTitle: String {
        switch state {
        case "failed", "failure": return "Update failed"
        case "rolled-back": return "Rolled back"
        case "ready": return candidateAvailable ? "Update available" : "Installed and running"
        case "starting", "building", "staging", "draining", "promoting", "restart", "rollback", "rollback-requested", "restart-requested":
            return state.replacingOccurrences(of: "-", with: " ").capitalized
        case "unknown": return "Unavailable"
        default: return candidateAvailable ? "Update available" : state.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

enum AdministrativeDrainPhase: String, Codable, Hashable, Sendable {
    case idle, preparing, waiting, complete, failed

    var isTerminal: Bool { self == .complete || self == .failed }
}

enum AdministrativeDrainBlockerCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case slotAdmission = "slot-admission"
    case promptPreflight = "prompt-preflight"
    case foregroundAgentOperation = "foreground-agent-operation"
    case queuedMutation = "queued-mutation"
    case compactionExport = "compaction-export"
    case detachedExtensionRun = "detached-extension-run"
    case terminalReceiptPersistence = "terminal-receipt-persistence"
    case extensionCommandPromptUI = "extension-command-prompt-ui"
    case administrativeProviderPackageOperation = "administrative-provider-package-operation"
    case automationDispatch = "automation-dispatch"
    case automationTerminalPersistence = "automation-terminal-persistence"
}

struct AdministrativeDrainSnapshot: Codable, Hashable, Sendable {
    let drainId: String
    let revision: Int
    let phase: AdministrativeDrainPhase
    let blockerCount: Int
    let blockerCounts: [String: Int]
    let omittedCount: Int
    let suspectProjectionCount: Int
}

struct GatewayRestartResponse: Codable, Hashable, Sendable {
    let restarting: Bool
    let scheduled: Bool
    let activeSessionIds: [String]
    let drain: AdministrativeDrainSnapshot?
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
    let gatewayChannel: String
    let sourceRevision: String?
    let buildFingerprint: String?
    let runtimeEpoch: String?

    init(gatewayVersion: String, piVersion: String, protocolVersion: Int, minProtocolVersion: Int,
         machineId: String, machineGroupID: String? = nil, machineName: String, capabilities: [String],
         gatewayChannel: String = "stable", sourceRevision: String? = nil,
         buildFingerprint: String? = nil, runtimeEpoch: String? = nil) {
        precondition(gatewayChannel == "stable" || gatewayChannel == "dev", "Gateway channel must be stable or dev")
        self.gatewayVersion = gatewayVersion
        self.piVersion = piVersion
        self.protocolVersion = protocolVersion
        self.minProtocolVersion = minProtocolVersion
        self.machineId = machineId
        self.machineGroupID = machineGroupID ?? machineId
        self.machineName = machineName
        self.capabilities = capabilities
        self.gatewayChannel = gatewayChannel
        self.sourceRevision = sourceRevision
        self.buildFingerprint = buildFingerprint
        self.runtimeEpoch = runtimeEpoch
    }

    private enum CodingKeys: String, CodingKey { case gatewayVersion, piVersion, protocolVersion, minProtocolVersion, machineId, machineGroupID, machineName, capabilities, gatewayChannel, sourceRevision, buildFingerprint, runtimeEpoch }

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
            gatewayChannel: try GatewayChannelPolicy.admit(values.decode(String.self, forKey: .gatewayChannel)),
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

struct IosDeviceInstallConfiguredTarget: Codable, Hashable, Sendable {
    let name: String
    let deviceType: String
    let connectionState: String
    let developerModeEnabled: Bool
}

struct IosDeviceInstallConfig: Codable, Hashable, Sendable {
    let schema: Int
    let kind: String
    let deviceId: String
    let gatewayChannel: String
    let sourceRoot: String?
    let target: IosDeviceInstallConfiguredTarget?
    let updatedAt: String

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(Int.self, forKey: .schema)
        kind = try values.decode(String.self, forKey: .kind)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        gatewayChannel = try values.decode(String.self, forKey: .gatewayChannel)
        sourceRoot = try values.decodeIfPresent(String.self, forKey: .sourceRoot)
        target = try values.decodeIfPresent(IosDeviceInstallConfiguredTarget.self, forKey: .target)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        try IosDeviceInstallProjectionPolicy.validate(config: self)
    }
}

struct IosDeviceInstallStatus: Codable, Hashable, Sendable {
    enum State: String, Codable, Hashable, Sendable {
        case requested, running, succeeded, failed
        var isActive: Bool { self == .requested || self == .running }
    }

    let schema: Int
    let kind: String
    let deviceId: String
    let state: State
    let commandId: String
    let targetName: String
    let startedAt: String
    let updatedAt: String
    let error: String?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(Int.self, forKey: .schema)
        kind = try values.decode(String.self, forKey: .kind)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        state = try values.decode(State.self, forKey: .state)
        commandId = try values.decode(String.self, forKey: .commandId)
        targetName = try values.decode(String.self, forKey: .targetName)
        startedAt = try values.decode(String.self, forKey: .startedAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        try IosDeviceInstallProjectionPolicy.validate(status: self)
    }
}

struct IosDeviceInstallAcknowledgement: Codable, Hashable, Sendable {
    let accepted: Bool
    let commandId: String
    let state: String

    func require(commandID: String) throws {
        guard accepted, commandId == commandID, state == "install-requested" else {
            throw GatewayFailure(
                code: "invalid_response",
                message: "The iOS install acknowledgement did not match the requested command.",
                retryable: true,
                details: nil
            )
        }
    }
}

enum IosDeviceInstallProjectionPolicy {
    static func validate(config: IosDeviceInstallConfig) throws {
        guard config.schema == 1,
              config.kind == "tron-ios-device-install-config",
              bounded(config.deviceId, maximum: 100),
              ["stable", "dev"].contains(config.gatewayChannel),
              config.sourceRoot.map({ (try? GatewayUpdateConfigPolicy.admitPath($0, name: "iOS source repository")) != nil }) ?? true,
              bounded(config.updatedAt, maximum: 64),
              GatewayTimestamp.parse(config.updatedAt) != nil else { throw invalid() }
        if let target = config.target {
            guard bounded(target.name, maximum: 320),
                  ["iPhone", "iPad"].contains(target.deviceType),
                  bounded(target.connectionState, maximum: 80) else { throw invalid() }
        }
    }

    static func validate(status: IosDeviceInstallStatus) throws {
        guard status.schema == 1,
              status.kind == "tron-ios-device-install-status",
              bounded(status.deviceId, maximum: 100),
              bounded(status.commandId, maximum: 160),
              bounded(status.targetName, maximum: 320),
              bounded(status.startedAt, maximum: 64),
              bounded(status.updatedAt, maximum: 64),
              GatewayTimestamp.parse(status.startedAt) != nil,
              GatewayTimestamp.parse(status.updatedAt) != nil,
              status.error.map({ bounded($0, maximum: 2_048) }) ?? true else { throw invalid() }
    }

    private static func bounded(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func invalid() -> GatewayFailure {
        GatewayFailure(
            code: "invalid_response",
            message: "The iOS device install projection is malformed.",
            retryable: true,
            details: nil
        )
    }
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
