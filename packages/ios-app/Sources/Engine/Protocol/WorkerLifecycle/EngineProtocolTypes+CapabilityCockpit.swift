import Foundation

struct CapabilityCockpitOverviewRequestDTO: Codable, Equatable, Sendable {
    var limit: UInt64?
}

struct CapabilityCockpitOverviewDTO: Codable, Equatable, Sendable {
    var schemaVersion: String
    var operation: String
    var summary: CapabilityCockpitSummaryDTO
    var families: [CapabilityCockpitFamilyDTO]
    var operations: [CapabilityCockpitOperationDTO]
    var scope: CapabilityCockpitScopeDTO
    var projection: CapabilityCockpitProjectionPolicyDTO
}

struct CapabilityCockpitSummaryDTO: Codable, Equatable, Sendable {
    var totalOperations: Int
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
    var rollbackAvailable: Int
    var title: String
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

    var id: String { family }
}

struct CapabilityCockpitOperationDTO: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var family: String
    var familyLabel: String
    var owner: CapabilityCockpitOwnerDTO
    var status: CapabilityCockpitStatusDTO
    var replacement: CapabilityCockpitReplacementDTO
    var binding: CapabilityCockpitBindingDTO
    var shadowTrial: CapabilityCockpitShadowTrialDTO
    var rollback: CapabilityCockpitRollbackDTO

    var id: String { name }
}

struct CapabilityCockpitOwnerDTO: Codable, Equatable, Sendable {
    var label: String
    var detail: String
    var backendOwner: String
    var source: String
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
    var governanceBoundary: String
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
