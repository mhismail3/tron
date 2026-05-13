import Foundation

// MARK: - Capability Identity

struct CapabilityIdentity: Codable, Equatable, Hashable, Sendable {
    var modelToolName: String?
    var contractId: String?
    var implementationId: String?
    var functionId: String?
    var pluginId: String?
    var workerId: String?
    var schemaDigest: String?
    var catalogRevision: UInt64?
    var trustTier: String?
    var riskLevel: String?
    var effectClass: String?
    var traceId: String?
    var rootInvocationId: String?
    var bindingDecisionId: String?

    init(
        modelToolName: String? = nil,
        contractId: String? = nil,
        implementationId: String? = nil,
        functionId: String? = nil,
        pluginId: String? = nil,
        workerId: String? = nil,
        schemaDigest: String? = nil,
        catalogRevision: UInt64? = nil,
        trustTier: String? = nil,
        riskLevel: String? = nil,
        effectClass: String? = nil,
        traceId: String? = nil,
        rootInvocationId: String? = nil,
        bindingDecisionId: String? = nil
    ) {
        self.modelToolName = modelToolName
        self.contractId = contractId
        self.implementationId = implementationId
        self.functionId = functionId
        self.pluginId = pluginId
        self.workerId = workerId
        self.schemaDigest = schemaDigest
        self.catalogRevision = catalogRevision
        self.trustTier = trustTier
        self.riskLevel = riskLevel
        self.effectClass = effectClass
        self.traceId = traceId
        self.rootInvocationId = rootInvocationId
        self.bindingDecisionId = bindingDecisionId
    }
}

struct CapabilityIndexStatusDTO: Codable, Equatable, Sendable {
    var lexical: Bool?
    var localVector: Bool?
    var cloudEmbeddings: Bool?
    var vectorStore: String?
    var embeddingModel: String?
    var state: String?
    var degradedReason: String?
    var dimension: Int?
    var updatedAt: String?
}

struct CapabilityStatusDTO: Codable, Equatable, Sendable {
    var catalogRevision: UInt64? = nil
    var registryRevision: UInt64? = nil
    var serverProfile: CapabilityServerProfileDTO? = nil
    var plugins: Int? = nil
    var implementations: Int? = nil
    var bindings: Int? = nil
    var documents: Int? = nil
    var inspectionHandles: Int? = nil
    var bindingDecisions: Int? = nil
    var auditEvents: Int? = nil
    var indexStatus: CapabilityIndexStatusDTO? = nil
    var snapshot: CapabilityRegistrySnapshotDTO? = nil
}

struct CapabilityServerProfileDTO: Codable, Equatable, Sendable {
    var profileName: String?
    var profileHash: String?
}

// MARK: - Registry Records

struct CapabilityRegistrySnapshotDTO: Codable, Equatable, Sendable {
    var plugins: [CapabilityPluginManifestDTO]?
    var implementations: [CapabilityImplementationDTO]?
    var bindings: [CapabilityBindingDTO]?
    var documents: [CapabilityIndexDocumentDTO]?
}

struct CapabilityContractDTO: Codable, Equatable, Sendable {
    var contractId: String
    var version: UInt64?
    var displayName: String?
    var description: String?
    var inputSchema: AnyCodable?
    var outputSchema: AnyCodable?
    var effectClass: String?
    var riskLevel: String?
    var idempotencyContract: AnyCodable?
    var approvalContract: AnyCodable?
    var leaseContract: AnyCodable?
    var compensationContract: AnyCodable?
    var examples: [AnyCodable]?
    var semanticTags: [String]?
}

struct CapabilityImplementationDTO: Codable, Equatable, Sendable {
    var implementationId: String
    var contractId: String?
    var pluginId: String?
    var workerId: String?
    var functionId: String?
    var version: UInt64?
    var health: String?
    var visibility: String?
    var latencyClass: String?
    var costClass: String?
    var trustTier: String?
    var authorityRequirements: AnyCodable?
    var runtimeRequirements: AnyCodable?
    var schemaDigest: String?
    var catalogRevision: UInt64?
    var provenance: AnyCodable?
    var conformanceState: String?
    var signatureStatus: String?
    var updatedAt: String?
}

struct CapabilityPluginManifestDTO: Codable, Equatable, Sendable {
    var id: String
    var name: String?
    var version: String?
    var publisher: String?
    var signatureStatus: String?
    var runtime: String?
    var namespaceClaims: [String]?
    var providedContracts: [String]?
    var providedImplementations: [String]?
    var requestedAuthorities: [String]?
    var trustTier: String?
    var visibilityCeiling: String?
    var conformanceState: String?
    var docs: AnyCodable?
    var examples: [AnyCodable]?
    var searchMetadata: AnyCodable?
}

struct CapabilityBindingDTO: Codable, Equatable, Sendable {
    var contractId: String
    var scopeKind: String?
    var scopeValue: String?
    var selectedImplementation: String
    var selectionPolicy: String?
    var secondaryImplementations: [String]?
    var enabled: Bool?
    var priority: Int?
    var updatedAt: String?
}

struct CapabilityIndexDocumentDTO: Codable, Equatable, Sendable {
    var kind: String?
    var capabilityId: String?
    var contractId: String?
    var implementationId: String?
    var pluginId: String?
    var workerId: String?
    var functionId: String?
    var catalogRevision: UInt64?
    var schemaDigest: String?
    var trustTier: String?
    var health: String?
    var visibility: String?
    var effectClass: String?
    var riskLevel: String?
    var text: String?
}

// MARK: - Search / Inspect / Execute

struct CapabilitySearchRequestDTO: Encodable, Sendable {
    var query: String
    var limit: Int? = nil
    var cursor: String? = nil
    var kind: String? = nil
    var contractId: String? = nil
    var namespace: String? = nil
    var pluginId: String? = nil
    var effect: String? = nil
    var riskMax: String? = nil
    var trustTierMin: String? = nil
    var includeUnavailable: Bool? = nil
    var scope: String? = nil
}

struct CapabilitySearchResponseDTO: Codable, Equatable, Sendable {
    var query: String?
    var catalogRevision: UInt64?
    var results: [CapabilityIndexHitDTO]?
    var nextCursor: String?
    var searchMode: CapabilityIndexStatusDTO?
}

struct CapabilityIndexHitDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String {
        [
            kind,
            capabilityId,
            implementationId,
            functionId,
            contractId,
            schemaDigest
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }
    var kind: String?
    var capabilityId: String?
    var contractId: String?
    var implementationId: String?
    var pluginId: String?
    var workerId: String?
    var functionId: String?
    var catalogRevision: UInt64?
    var schemaDigest: String?
    var trustTier: String?
    var health: String?
    var visibility: String?
    var effectClass: String?
    var riskLevel: String?
    var lexicalScore: Double?
    var vectorScore: Double?
    var fusedScore: Double?
    var matchedBy: String?
    var snippet: String?
    var requiresInspect: Bool?
}

struct CapabilityInspectionDTO: Codable, Equatable, Sendable {
    var contract: CapabilityContractDTO?
    var implementation: CapabilityImplementationDTO?
    var binding: CapabilityBindingDTO?
    var bindingDecision: CapabilityBindingDecisionDTO?
    var inspectionHandle: CapabilityInspectionHandleDTO?
    var executionRequirements: AnyCodable?
    var docs: AnyCodable?
}

struct CapabilityInspectionHandleDTO: Codable, Equatable, Sendable {
    var handle: String
    var catalogRevision: UInt64?
    var functionRevision: UInt64?
    var schemaDigest: String?
}

struct CapabilityBindingDecisionDTO: Codable, Equatable, Sendable {
    var contractId: String?
    var selectedImplementation: String?
    var selectedFunctionId: String?
    var selectionPolicy: String?
    var rejectedCandidates: [CapabilityRejectedCandidateDTO]?
    var catalogRevision: UInt64?
    var schemaDigest: String?
}

struct CapabilityRejectedCandidateDTO: Codable, Equatable, Sendable {
    var implementationId: String?
    var functionId: String?
    var reason: String?
}

struct CapabilityExecutionDTO: Codable, Equatable, Sendable {
    var status: String?
    var traceId: String?
    var rootInvocationId: String?
    var childInvocations: [String]?
    var selectedImplementation: String?
    var functionId: String?
    var catalogRevision: UInt64?
    var functionRevision: UInt64?
    var output: AnyCodable?
    var approvalState: AnyCodable?
    var pluginVersions: [String]?
    var bindingDecision: CapabilityBindingDecisionDTO?
    var schemaDigest: String?
}

// MARK: - Admin / Audit

struct CapabilityPluginInspectDTO: Codable, Equatable, Sendable {
    var manifest: CapabilityPluginManifestDTO?
    var implementations: [CapabilityImplementationDTO]?
}

struct CapabilityAuditQueryDTO: Encodable, Sendable {
    var eventType: String?
    var traceId: String?
    var limit: Int?
    var revealPayloads: Bool?
}

struct CapabilityAuditQueryResultDTO: Codable, Equatable, Sendable {
    var events: [CapabilityAuditEventDTO]
    var redacted: Bool?
}

struct CapabilityAuditEventDTO: Codable, Equatable, Sendable, Identifiable {
    var id: String?
    var eventType: String?
    var traceId: String?
    var payload: AnyCodable?
    var payloadSummary: AnyCodable?
    var createdAt: String?
    var redacted: Bool?
}

struct CapabilityPolicyDTO: Codable, Equatable, Sendable {
    var manifest: String?
    var searchPolicy: String?
    var contextPrimerPolicy: String?
    var allowedCapabilities: [String]?
    var deniedCapabilities: [String]?
    var exposeInteractiveTools: Bool?
    var removeSpawnToolsAtMaxDepth: Bool?
}

struct CapabilityPolicyGetDTO: Codable, Equatable, Sendable {
    var profileName: String?
    var profileHash: String?
    var policyId: String?
    var capabilityPolicies: [String: CapabilityPolicyDTO]?
}

struct CapabilityPolicyValidationDTO: Codable, Equatable, Sendable {
    var valid: Bool
    var policy: CapabilityPolicyDTO?
    var errors: [String]?
}

struct CapabilityPrimitiveResultDTO: Codable, Equatable, Sendable {
    var content: AnyCodable?
    var details: AnyCodable?
    var isError: Bool?
    var stopTurn: Bool?
}
