import Foundation

// MARK: - Capability Identity

struct CapabilityIdentity: Codable, Equatable, Hashable, Sendable {
    var modelPrimitiveName: String?
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
    var themeColor: String?
    var presentationHints: [String: AnyCodable]?

    init(
        modelPrimitiveName: String? = nil,
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
        bindingDecisionId: String? = nil,
        themeColor: String? = nil,
        presentationHints: [String: AnyCodable]? = nil
    ) {
        self.modelPrimitiveName = modelPrimitiveName
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
        self.themeColor = themeColor
        self.presentationHints = presentationHints
    }
}

struct CapabilityPrimitiveResultDTO: Codable, Equatable, Sendable {
    var content: AnyCodable?
    var details: AnyCodable?
    var isError: Bool?
    var stopTurn: Bool?
}
