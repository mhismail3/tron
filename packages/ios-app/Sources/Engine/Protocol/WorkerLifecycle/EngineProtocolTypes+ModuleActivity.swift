import Foundation

struct ModuleActivityOverviewRequestDTO: Codable, Equatable, Sendable {
    var limit: UInt64?
}

struct ModuleActivityOverviewDTO: Codable, Equatable, Sendable {
    var schemaVersion: String
    var operation: String
    var summary: ModuleActivitySummaryDTO
    var timeline: [ModuleActivityItemDTO]
    var blocked: [ModuleActivityItemDTO]
    var waiting: [ModuleActivityItemDTO]
    var resources: [ModuleActivityResourceSummaryDTO]
    var projection: ModuleActivityProjectionPolicyDTO
}

struct ModuleActivitySummaryDTO: Codable, Equatable, Sendable {
    var total: Int
    var active: Int
    var waiting: Int
    var blocked: Int
    var ready: Int
    var recorded: Int
    var title: String
    var detail: String
}

struct ModuleActivityItemDTO: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var resourceId: String
    var resourceKind: String
    var status: String
    var state: String
    var title: String
    var detail: String
    var authorityLabels: [String]
    var touchedResources: [ModuleActivityResourceTouchDTO]
    var rollbackStatus: ModuleActivityGateStatusDTO
    var quarantineStatus: ModuleActivityGateStatusDTO
    var runtimeAuthorizationStatus: ModuleActivityGateStatusDTO
    var updatedAt: String
}

struct ModuleActivityGateStatusDTO: Codable, Equatable, Sendable {
    var label: String
    var state: String
    var blocked: Bool
    var waiting: Bool
}

struct ModuleActivityResourceTouchDTO: Codable, Equatable, Sendable {
    var label: String
    var total: Int
    var truncated: Bool
}

struct ModuleActivityResourceSummaryDTO: Codable, Equatable, Sendable {
    var kind: String
    var total: Int
    var active: Int
    var waiting: Int
    var blocked: Int
}

struct ModuleActivityProjectionPolicyDTO: Codable, Equatable, Sendable {
    var allowlist: String
    var serverOwnedTruth: Bool
    var metadataOnly: Bool
    var rawPayloadsReturned: Bool
    var rawCommandsReturned: Bool
    var rawLogsReturned: Bool
    var fileContentsReturned: Bool
    var absolutePathsReturned: Bool
    var grantIdsReturned: Bool
    var authorityIdsReturned: Bool
    var traceIdsReturned: Bool
    var invocationIdsReturned: Bool
    var tokenLikeMaterialReturned: Bool
    var boundedItems: Bool
}
