import Foundation

struct AgentBriefingOverviewRequestDTO: Codable, Equatable, Sendable {
    var limit: UInt64?
}

struct AgentBriefingOverviewDTO: Codable, Equatable, Sendable {
    var schemaVersion: String
    var operation: String
    var summary: AgentBriefingSummaryDTO
    var sections: [AgentBriefingSectionDTO]
    var scope: AgentBriefingScopeDTO
    var projection: AgentBriefingProjectionPolicyDTO
}

struct AgentBriefingSummaryDTO: Codable, Equatable, Sendable {
    var title: String
    var detail: String
    var activeWorkCount: Int
    var needsYouCount: Int
    var weakPointCount: Int
    var activityCount: Int
    var degraded: Bool
}

struct AgentBriefingSectionDTO: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var question: String
    var narrative: String
    var items: [AgentBriefingItemDTO]
    var emptyState: String
    var drilldownAvailable: Bool
}

struct AgentBriefingItemDTO: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var detail: String
    var status: String
    var evidence: AgentBriefingEvidenceDTO?
}

struct AgentBriefingEvidenceDTO: Codable, Equatable, Sendable {
    var label: String?
    var resourceKind: String?
    var updatedAt: String?
    var providerSafe: Bool?
}

struct AgentBriefingScopeDTO: Codable, Equatable, Sendable {
    var sessionScoped: Bool
    var workspaceScoped: Bool
    var exactScopeRequired: Bool
    var payloadScopeTrusted: Bool
}

struct AgentBriefingProjectionPolicyDTO: Codable, Equatable, Sendable {
    var allowlist: String
    var serverOwnedTruth: Bool
    var projectionOnly: Bool
    var autonomyBehaviorCreated: Bool
    var metadataOnly: Bool
    var rawPayloadsReturned: Bool
    var rawCommandsReturned: Bool
    var rawLogsReturned: Bool
    var promptBodiesReturned: Bool
    var fileContentsReturned: Bool
    var absolutePathsReturned: Bool
    var grantIdsReturned: Bool
    var authorityIdsReturned: Bool
    var traceIdsReturned: Bool
    var invocationIdsReturned: Bool
    var tokenLikeMaterialReturned: Bool
    var boundedItems: Bool
    var sourceProjection: String
}
