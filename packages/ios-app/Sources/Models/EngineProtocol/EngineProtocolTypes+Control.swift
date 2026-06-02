import Foundation

struct ControlSnapshotDTO: Codable, Equatable, Sendable {
    var catalogRevision: UInt64?
    var workers: [AnyCodable]?
    var capabilities: [AnyCodable]?
    var resourceTypes: [AnyCodable]?
    var activeGoals: [AnyCodable]?
    var modulePackages: [AnyCodable]? = nil
    var moduleConfigs: [AnyCodable]? = nil
    var activationRecords: [AnyCodable]? = nil
    var moduleHealth: [AnyCodable]? = nil
    var moduleSourceTrust: [AnyCodable]? = nil
    var invocations: [AnyCodable]?
    var grants: [AnyCodable]?
    var queues: [AnyCodable]?
    var leases: [AnyCodable]?
    var approvals: [AnyCodable]?
    var storage: AnyCodable?
    var integrityWarnings: [AnyCodable]?
    var availableActions: [AnyCodable]?
    var uiSurfaceRefs: [UiSurfaceRefDTO]? = nil
}

struct ControlInspectRequestDTO: Codable, Equatable, Sendable {
    var targetType: String
    var targetId: String
    var includeFullPayloads: Bool?
}

struct ControlInspectDTO: Codable, Equatable, Sendable {
    var targetType: String?
    var targetId: String?
    var graph: AnyCodable?
    var availableActions: [AnyCodable]?
    var uiSurfaceRefs: [UiSurfaceRefDTO]? = nil
}
