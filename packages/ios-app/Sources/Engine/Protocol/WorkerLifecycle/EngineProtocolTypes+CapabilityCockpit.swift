import Foundation

struct CapabilityCockpitOverviewRequestDTO: Codable, Equatable, Sendable {
    var limit: UInt64?
}

struct CapabilityCockpitOverviewDTO: Codable, Equatable, Sendable {
    var schemaVersion: String
    var operation: String
    var summary: CapabilityCockpitSummaryDTO
    var operationList: CapabilityCockpitOperationListDTO
    var resourceScan: CapabilityCockpitResourceScanDTO
    var families: [CapabilityCockpitFamilyDTO]
    var routeStories: [CapabilityCockpitRouteStoryDTO]? = nil
    var operations: [CapabilityCockpitOperationDTO]
    var scope: CapabilityCockpitScopeDTO
    var projection: CapabilityCockpitProjectionPolicyDTO
}

struct CapabilityCockpitSummaryDTO: Codable, Equatable, Sendable {
    var totalOperations: Int
    var returnedOperations: Int
    var operationListComplete: Bool
    var operationListTruncated: Bool
    var resourceScanComplete: Bool
    var resourceScanTruncated: Bool
    var kernelLocked: Int
    var governanceLocked: Int
    var recordPlane: Int
    var adapterReplaceable: Int
    var moduleOwned: Int
    var deferred: Int
    var bindingRequests: Int
    var bindingApproved: Int
    var bindingRejected: Int
    var activePolicies: Int
    var shadowRequests: Int
    var shadowRuns: Int
    var routeCandidates: Int? = nil
    var activeRoutes: Int? = nil
    var routeEvents: Int? = nil
    var routedInvocations: Int? = nil
    var failedClosedRoutes: Int? = nil
    var routeRollbacks: Int? = nil
    var rollbackAvailable: Int
    var title: String
    var detail: String
}

struct CapabilityCockpitOperationListDTO: Codable, Equatable, Sendable {
    var totalOperations: Int
    var returnedOperations: Int
    var requestedLimit: Int
    var complete: Bool
    var truncated: Bool
    var state: String
    var label: String
    var detail: String
}

struct CapabilityCockpitResourceScanDTO: Codable, Equatable, Sendable {
    var queries: Int
    var scannedResources: Int
    var appliedResources: Int
    var limitPerKindScope: Int
    var complete: Bool
    var truncated: Bool
    var truncatedQueries: Int
    var state: String
    var label: String
    var detail: String
}

struct CapabilityCockpitFamilyDTO: Codable, Equatable, Identifiable, Sendable {
    var family: String
    var label: String
    var operations: Int
    var kernelLocked: Int
    var governanceLocked: Int
    var recordPlane: Int
    var adapterReplaceable: Int
    var moduleOwned: Int
    var bindingActivity: Int
    var shadowActivity: Int
    var routeActivity: Int? = nil

    var id: String { family }
}

struct CapabilityCockpitRouteStoryDTO: Codable, Equatable, Identifiable, Sendable {
    var kind: String
    var operation: String
    var title: String
    var detail: String
    var status: String
    var evidenceCount: Int
    var lastUpdatedAt: String?
    var drillDownLabel: String

    var id: String { "\(kind):\(operation):\(lastUpdatedAt ?? "none")" }
}

struct CapabilityCockpitOperationDTO: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var family: String
    var familyLabel: String
    var capabilityPool: CapabilityCockpitPoolDTO? = nil
    var agentUsage: CapabilityCockpitAgentUsageDTO? = nil
    var owner: CapabilityCockpitOwnerDTO
    var status: CapabilityCockpitStatusDTO
    var replacement: CapabilityCockpitReplacementDTO
    var readiness: CapabilityCockpitReadinessDTO
    var binding: CapabilityCockpitBindingDTO
    var shadowTrial: CapabilityCockpitShadowTrialDTO
    var route: CapabilityCockpitRouteDTO? = nil
    var rollback: CapabilityCockpitRollbackDTO

    var id: String { name }
}

struct CapabilityCockpitPoolDTO: Codable, Equatable, Sendable {
    var surface: String
    var audience: String
    var replacementClass: String
    var agentDefaultVisibility: String
    var minimalityDecision: String
    var evolutionPath: String
}

struct CapabilityCockpitAgentUsageDTO: Codable, Equatable, Sendable {
    var callable: Bool
    var tool: String?
    var operation: String?
    var defaultUse: String?
    var failureRecovery: String?
    var preflight: CapabilityCockpitAgentPreflightDTO?
}

struct CapabilityCockpitAgentPreflightDTO: Codable, Equatable, Sendable {
    var authority: String?
    var evidence: String?
    var networkPolicy: String?
    var beforeCalling: String?
    var authorityScopes: [String]?
    var resourceSelectors: [String]?
    var requiredPayloadFields: [String]?
}

struct CapabilityCockpitOwnerDTO: Codable, Equatable, Sendable {
    var label: String
    var detail: String
    var source: String
    var metadataSourceLabel: String
    var projectionSourceLabel: String
}

struct CapabilityCockpitStatusDTO: Codable, Equatable, Sendable {
    var kind: String
    var label: String
    var detail: String
    var builtIn: Bool
    var moduleOwned: Bool
    var locked: Bool
}

struct CapabilityCockpitReplacementDTO: Codable, Equatable, Sendable {
    var canShadow: Bool
    var canReplace: Bool
    var canExtend: Bool
    var label: String
    var detail: String
    var target: CapabilityCockpitReplacementTargetDTO
    var governanceBoundary: String
}

struct CapabilityCockpitReplacementTargetDTO: Codable, Equatable, Sendable {
    var label: String
    var detail: String
}

struct CapabilityCockpitReadinessDTO: Codable, Equatable, Sendable {
    var state: String
    var label: String
    var detail: String
    var nextActionLabel: String
    var nextActionDetail: String
}

struct CapabilityCockpitBindingDTO: Codable, Equatable, Sendable {
    var requested: Int
    var approved: Int
    var rejected: Int
    var activePolicies: Int
    var failedReplacementAttempts: Int
    var latestState: String?
    var lastUpdatedAt: String?
    var detail: String
}

struct CapabilityCockpitShadowTrialDTO: Codable, Equatable, Sendable {
    var requested: Int
    var approved: Int
    var rejected: Int
    var runs: Int
    var passed: Int
    var failed: Int
    var aborted: Int
    var disabled: Int
    var latestState: String?
    var lastUpdatedAt: String?
    var availableForThisOperation: Bool
    var detail: String
}

struct CapabilityCockpitRouteDTO: Codable, Equatable, Sendable {
    var candidates: Int = 0
    var bindings: Int = 0
    var activeRoutes: Int = 0
    var routeEvents: Int = 0
    var routedInvocations: Int = 0
    var failedClosed: Int = 0
    var disabled: Int = 0
    var rolledBack: Int = 0
    var rollbackRecords: Int = 0
    var rollbackAvailable: Bool = false
    var disableAvailable: Bool = false
    var latestState: String? = nil
    var lastUpdatedAt: String? = nil
    var state: String = "none"
    var label: String = "No runtime route"
    var detail: String = "No dynamic replacement route records exist for this operation in the current scope."
}

struct CapabilityCockpitRollbackDTO: Codable, Equatable, Sendable {
    var available: Bool
    var disableAvailable: Bool
    var abortAvailable: Bool
    var boundary: String
    var detail: String
}

struct CapabilityCockpitScopeDTO: Codable, Equatable, Sendable {
    var sessionScoped: Bool
    var workspaceScoped: Bool
    var exactScopeRequired: Bool
    var source: String
}

struct CapabilityCockpitProjectionPolicyDTO: Codable, Equatable, Sendable {
    var allowlist: String
    var serverOwnedTruth: Bool
    var projectionOnly: Bool
    var metadataOnly: Bool
    var autonomyBehaviorCreated: Bool
    var runtimeRoutingChanged: Bool
    var dispatchTableMutated: Bool
    var hotSwapPerformed: Bool
    var moduleActivated: Bool
    var moduleExecuted: Bool
    var rawResourceIdsReturned: Bool
    var rawLocalPathsReturned: Bool
    var rawEnvValuesReturned: Bool
    var rawSecretsReturned: Bool
    var rawCommandsReturned: Bool
    var rawLogsReturned: Bool
    var rawCodeReturned: Bool
    var rawFileContentsReturned: Bool
    var rawGrantIdsReturned: Bool
    var rawAuthorityIdsReturned: Bool
    var traceIdsReturned: Bool
    var invocationIdsReturned: Bool
    var tokenLikeMaterialReturned: Bool
    var hiddenChainOfThoughtReturned: Bool
    var boundedItems: Bool
}
