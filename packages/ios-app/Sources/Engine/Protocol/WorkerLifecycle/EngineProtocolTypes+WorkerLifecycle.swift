import Foundation

// MARK: - Worker Lifecycle Catalog DTOs

struct WorkerCatalogDefinitionDTO: Decodable, Equatable, Sendable, Identifiable {
    var id: String
    var revision: UInt64?
    var kind: String?
    var lifecycle: String?
    var ownerActor: String?
    var authorityGrant: String?
    var namespaceClaims: [String]?
    var visibility: String?
    var provenance: [String: AnyCodable]?
    var raw: [String: AnyCodable]?

    private enum CodingKeys: String, CodingKey {
        case id
        case revision
        case kind
        case lifecycle
        case ownerActor
        case ownerActorSnake = "owner_actor"
        case authorityGrant
        case authorityGrantSnake = "authority_grant"
        case namespaceClaims
        case namespaceClaimsSnake = "namespace_claims"
        case visibility
        case provenance
    }

    init(
        id: String,
        revision: UInt64? = nil,
        kind: String? = nil,
        lifecycle: String? = nil,
        ownerActor: String? = nil,
        authorityGrant: String? = nil,
        namespaceClaims: [String]? = nil,
        visibility: String? = nil,
        provenance: [String: AnyCodable]? = nil,
        raw: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.revision = revision
        self.kind = kind
        self.lifecycle = lifecycle
        self.ownerActor = ownerActor
        self.authorityGrant = authorityGrant
        self.namespaceClaims = namespaceClaims
        self.visibility = visibility
        self.provenance = provenance
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        revision = try container.decodeFlexibleUInt64IfPresent(forKey: .revision)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        lifecycle = try container.decodeIfPresent(String.self, forKey: .lifecycle)
        ownerActor = try container.decodeStringIfPresent(first: .ownerActor, fallback: .ownerActorSnake)
        authorityGrant = try container.decodeStringIfPresent(first: .authorityGrant, fallback: .authorityGrantSnake)
        namespaceClaims = try container.decodeArrayIfPresent(first: .namespaceClaims, fallback: .namespaceClaimsSnake)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
        provenance = try container.decodeIfPresent([String: AnyCodable].self, forKey: .provenance)
        raw = try? [String: AnyCodable](from: decoder)
    }
}

struct FunctionCatalogDefinitionDTO: Decodable, Equatable, Sendable, Identifiable {
    var id: String
    var revision: UInt64?
    var ownerWorker: String?
    var description: String?
    var tags: [String]?
    var visibility: String?
    var effectClass: String?
    var riskLevel: String?
    var health: String?
    var opaqueResponse: Bool?
    var requiredAuthority: [String: AnyCodable]?
    var requestSchema: AnyCodable?
    var responseSchema: AnyCodable?
    var metadata: [String: AnyCodable]?
    var raw: [String: AnyCodable]?

    private enum CodingKeys: String, CodingKey {
        case id
        case revision
        case ownerWorker
        case ownerWorkerSnake = "owner_worker"
        case description
        case tags
        case visibility
        case effectClass
        case effectClassSnake = "effect_class"
        case riskLevel
        case riskLevelSnake = "risk_level"
        case health
        case opaqueResponse
        case opaqueResponseSnake = "opaque_response"
        case requiredAuthority
        case requiredAuthoritySnake = "required_authority"
        case requestSchema
        case requestSchemaSnake = "request_schema"
        case responseSchema
        case responseSchemaSnake = "response_schema"
        case metadata
    }

    init(
        id: String,
        revision: UInt64? = nil,
        ownerWorker: String? = nil,
        description: String? = nil,
        tags: [String]? = nil,
        visibility: String? = nil,
        effectClass: String? = nil,
        riskLevel: String? = nil,
        health: String? = nil,
        opaqueResponse: Bool? = nil,
        requiredAuthority: [String: AnyCodable]? = nil,
        requestSchema: AnyCodable? = nil,
        responseSchema: AnyCodable? = nil,
        metadata: [String: AnyCodable]? = nil,
        raw: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.revision = revision
        self.ownerWorker = ownerWorker
        self.description = description
        self.tags = tags
        self.visibility = visibility
        self.effectClass = effectClass
        self.riskLevel = riskLevel
        self.health = health
        self.opaqueResponse = opaqueResponse
        self.requiredAuthority = requiredAuthority
        self.requestSchema = requestSchema
        self.responseSchema = responseSchema
        self.metadata = metadata
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        revision = try container.decodeFlexibleUInt64IfPresent(forKey: .revision)
        ownerWorker = try container.decodeStringIfPresent(first: .ownerWorker, fallback: .ownerWorkerSnake)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
        effectClass = try container.decodeStringIfPresent(first: .effectClass, fallback: .effectClassSnake)
        riskLevel = try container.decodeStringIfPresent(first: .riskLevel, fallback: .riskLevelSnake)
        health = try container.decodeIfPresent(String.self, forKey: .health)
        opaqueResponse = try container.decodeBoolIfPresent(first: .opaqueResponse, fallback: .opaqueResponseSnake)
        requiredAuthority = try container.decodeDictionaryIfPresent(first: .requiredAuthority, fallback: .requiredAuthoritySnake)
        requestSchema = try container.decodeAnyCodableIfPresent(first: .requestSchema, fallback: .requestSchemaSnake)
        responseSchema = try container.decodeAnyCodableIfPresent(first: .responseSchema, fallback: .responseSchemaSnake)
        metadata = try container.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
        raw = try? [String: AnyCodable](from: decoder)
    }
}

struct TriggerCatalogDefinitionDTO: Decodable, Equatable, Sendable, Identifiable {
    var id: String
    var revision: UInt64?
    var ownerWorker: String?
    var triggerType: String?
    var targetFunction: String?
    var deliveryMode: String?
    var authorityGrant: String?
    var visibility: String?
    var config: AnyCodable?
    var raw: [String: AnyCodable]?

    private enum CodingKeys: String, CodingKey {
        case id
        case revision
        case ownerWorker
        case ownerWorkerSnake = "owner_worker"
        case triggerType
        case triggerTypeSnake = "trigger_type"
        case targetFunction
        case targetFunctionSnake = "target_function"
        case deliveryMode
        case deliveryModeSnake = "delivery_mode"
        case authorityGrant
        case authorityGrantSnake = "authority_grant"
        case visibility
        case config
    }

    init(
        id: String,
        revision: UInt64? = nil,
        ownerWorker: String? = nil,
        triggerType: String? = nil,
        targetFunction: String? = nil,
        deliveryMode: String? = nil,
        authorityGrant: String? = nil,
        visibility: String? = nil,
        config: AnyCodable? = nil,
        raw: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.revision = revision
        self.ownerWorker = ownerWorker
        self.triggerType = triggerType
        self.targetFunction = targetFunction
        self.deliveryMode = deliveryMode
        self.authorityGrant = authorityGrant
        self.visibility = visibility
        self.config = config
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        revision = try container.decodeFlexibleUInt64IfPresent(forKey: .revision)
        ownerWorker = try container.decodeStringIfPresent(first: .ownerWorker, fallback: .ownerWorkerSnake)
        triggerType = try container.decodeStringIfPresent(first: .triggerType, fallback: .triggerTypeSnake)
        targetFunction = try container.decodeStringIfPresent(first: .targetFunction, fallback: .targetFunctionSnake)
        deliveryMode = try container.decodeStringIfPresent(first: .deliveryMode, fallback: .deliveryModeSnake)
        authorityGrant = try container.decodeStringIfPresent(first: .authorityGrant, fallback: .authorityGrantSnake)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
        config = try container.decodeIfPresent(AnyCodable.self, forKey: .config)
        raw = try? [String: AnyCodable](from: decoder)
    }
}

struct TriggerTypeCatalogDefinitionDTO: Decodable, Equatable, Sendable, Identifiable {
    var id: String
    var ownerWorker: String?
    var description: String?
    var allowedDeliveryModes: [String]?
    var visibility: String?
    var configSchema: AnyCodable?
    var raw: [String: AnyCodable]?

    private enum CodingKeys: String, CodingKey {
        case id
        case ownerWorker
        case ownerWorkerSnake = "owner_worker"
        case description
        case allowedDeliveryModes
        case allowedDeliveryModesSnake = "allowed_delivery_modes"
        case visibility
        case configSchema
        case configSchemaSnake = "config_schema"
    }

    init(
        id: String,
        ownerWorker: String? = nil,
        description: String? = nil,
        allowedDeliveryModes: [String]? = nil,
        visibility: String? = nil,
        configSchema: AnyCodable? = nil,
        raw: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.ownerWorker = ownerWorker
        self.description = description
        self.allowedDeliveryModes = allowedDeliveryModes
        self.visibility = visibility
        self.configSchema = configSchema
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ownerWorker = try container.decodeStringIfPresent(first: .ownerWorker, fallback: .ownerWorkerSnake)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        allowedDeliveryModes = try container.decodeArrayIfPresent(first: .allowedDeliveryModes, fallback: .allowedDeliveryModesSnake)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
        configSchema = try container.decodeAnyCodableIfPresent(first: .configSchema, fallback: .configSchemaSnake)
        raw = try? [String: AnyCodable](from: decoder)
    }
}

struct CatalogDefinitionDecodeIssue: Equatable, Sendable, Identifiable {
    var category: String
    var index: Int
    var message: String

    var id: String { "\(category):\(index)" }
}

struct CatalogDefinitionDecodeResult<Definition: Equatable & Sendable>: Equatable, Sendable {
    var definitions: [Definition]
    var issues: [CatalogDefinitionDecodeIssue]
}

// MARK: - Worker Lifecycle Action DTOs

struct WorkerLifecycleManifestRequestDTO: Codable, Equatable, Sendable {
    var manifest: [String: AnyCodable]
    var sessionId: String?
    var workspaceId: String?
}

struct WorkerLifecycleProposalRequestDTO: Codable, Equatable, Sendable {
    var manifest: [String: AnyCodable]
    var summary: String
    var sessionId: String?
    var workspaceId: String?
}

struct WorkerLifecyclePackageRefRequestDTO: Codable, Equatable, Sendable {
    var packageId: String
    var packageVersion: String
    var reason: String?
    var sessionId: String?
    var workspaceId: String?
}

struct WorkerLifecycleStopRequestDTO: Codable, Equatable, Sendable {
    var launchAttemptResourceId: String
    var reason: String?
    var sessionId: String?
    var workspaceId: String?
}

struct CatalogDiscoveryReportRequestDTO: Codable, Equatable, Sendable {
    var reason: String?
    var includeProtectedCounts: Bool?
    var sessionId: String?
    var workspaceId: String?
}

struct CatalogDiscoveryResourceRefDTO: Codable, Equatable, Sendable {
    var kind: String
    var resourceId: String
    var versionId: String?
    var role: String?
}

struct CatalogDiscoveryReportResultDTO: Codable, Equatable, Sendable {
    var status: String
    var reportResourceId: String?
    var streamCursor: UInt64?
    var summary: [String: AnyCodable]?
    var resourceRefs: [CatalogDiscoveryResourceRefDTO]?
}

struct WorkerLifecycleResultDTO: Codable, Equatable, Sendable {
    var status: String
    var packageResourceId: String?
    var installationResourceId: String?
    var proposalResourceId: String?
    var launchAttemptResourceId: String?
    var conformanceReportResourceId: String?
    var streamCursor: UInt64?
    var workerToken: [String: AnyCodable]?
}

// MARK: - Worker Lifecycle Resource DTOs

enum WorkerLifecycleResourceKind: String, CaseIterable, Sendable {
    case package = "worker_package"
    case installation = "worker_package_installation"
    case proposal = "worker_package_proposal"
    case conformanceReport = "worker_package_conformance_report"
    case launchAttempt = "worker_launch_attempt"
    case catalogDiscoveryReport = "catalog_discovery_report"
    case uiSurface = "ui_surface"
}

struct ResourceListRequestDTO: Codable, Equatable, Sendable {
    var kind: String?
    var scopeKind: String?
    var scopeValue: String?
    var lifecycle: String?
    var limit: UInt64?
}

struct ResourceListResultDTO: Codable, Equatable, Sendable {
    var resources: [EngineResourceDTO]
}

struct ResourceInspectRequestDTO: Codable, Equatable, Sendable {
    var resourceId: String
}

struct ResourceInspectResultDTO: Codable, Equatable, Sendable {
    var inspection: EngineResourceInspectionDTO?
}

struct EngineResourceInspectionDTO: Codable, Equatable, Sendable {
    var resource: EngineResourceDTO
    var versions: [EngineResourceVersionDTO]
    var outgoingLinks: [AnyCodable]?
    var incomingLinks: [AnyCodable]?
    var events: [AnyCodable]?
}

struct EngineResourceDTO: Codable, Equatable, Sendable, Identifiable {
    var resourceId: String
    var kind: String
    var schemaId: String?
    var scope: AnyCodable?
    var ownerWorkerId: String?
    var ownerActorId: String?
    var lifecycle: String
    var policy: [String: AnyCodable]?
    var currentVersionId: String?
    var traceId: String?
    var createdByInvocationId: String?
    var createdAt: String?
    var updatedAt: String?

    var id: String { resourceId }
}

struct EngineResourceVersionDTO: Codable, Equatable, Sendable, Identifiable {
    var versionId: String
    var resourceId: String
    var parentVersionId: String?
    var contentHash: String?
    var state: String?
    var payload: [String: AnyCodable]?
    var locations: [AnyCodable]?
    var createdByInvocationId: String?
    var traceId: String?
    var createdAt: String?

    var id: String { versionId }
}

// MARK: - Catalog Snapshot Decoding Helpers

extension CatalogSnapshotDTO {
    func workerDefinitionResult() -> CatalogDefinitionDecodeResult<WorkerCatalogDefinitionDTO> {
        decodeCatalogDefinitions(workers, category: "workers")
    }

    func functionDefinitionResult() -> CatalogDefinitionDecodeResult<FunctionCatalogDefinitionDTO> {
        decodeCatalogDefinitions(functions, category: "functions")
    }

    func triggerDefinitionResult() -> CatalogDefinitionDecodeResult<TriggerCatalogDefinitionDTO> {
        decodeCatalogDefinitions(triggers, category: "triggers")
    }

    func triggerTypeDefinitionResult() -> CatalogDefinitionDecodeResult<TriggerTypeCatalogDefinitionDTO> {
        decodeCatalogDefinitions(triggerTypes, category: "triggerTypes")
    }

    private func decodeCatalogDefinitions<T: Decodable & Equatable & Sendable>(
        _ values: [AnyCodable]?,
        category: String
    ) -> CatalogDefinitionDecodeResult<T> {
        guard let values else {
            return CatalogDefinitionDecodeResult(definitions: [], issues: [])
        }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var definitions: [T] = []
        var issues: [CatalogDefinitionDecodeIssue] = []
        for (index, value) in values.enumerated() {
            do {
                let data = try encoder.encode(value)
                definitions.append(try decoder.decode(T.self, from: data))
            } catch {
                issues.append(
                    CatalogDefinitionDecodeIssue(
                        category: category,
                        index: index,
                        message: error.localizedDescription
                    )
                )
            }
        }
        return CatalogDefinitionDecodeResult(definitions: definitions, issues: issues)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleUInt64IfPresent(forKey key: Key) throws -> UInt64? {
        if let value = try decodeIfPresent(UInt64.self, forKey: key) {
            return value
        }
        if let value = try decodeIfPresent(Int.self, forKey: key), value >= 0 {
            return UInt64(value)
        }
        if let value = try decodeIfPresent(Double.self, forKey: key), value >= 0 {
            return UInt64(exactly: value.rounded(.towardZero))
        }
        return nil
    }

    func decodeStringIfPresent(first: Key, fallback: Key) throws -> String? {
        if let value = try decodeIfPresent(String.self, forKey: first) {
            return value
        }
        return try decodeIfPresent(String.self, forKey: fallback)
    }

    func decodeArrayIfPresent(first: Key, fallback: Key) throws -> [String]? {
        if let value = try decodeIfPresent([String].self, forKey: first) {
            return value
        }
        return try decodeIfPresent([String].self, forKey: fallback)
    }

    func decodeBoolIfPresent(first: Key, fallback: Key) throws -> Bool? {
        if let value = try decodeIfPresent(Bool.self, forKey: first) {
            return value
        }
        return try decodeIfPresent(Bool.self, forKey: fallback)
    }

    func decodeDictionaryIfPresent(first: Key, fallback: Key) throws -> [String: AnyCodable]? {
        if let value = try decodeIfPresent([String: AnyCodable].self, forKey: first) {
            return value
        }
        return try decodeIfPresent([String: AnyCodable].self, forKey: fallback)
    }

    func decodeAnyCodableIfPresent(first: Key, fallback: Key) throws -> AnyCodable? {
        if let value = try decodeIfPresent(AnyCodable.self, forKey: first) {
            return value
        }
        return try decodeIfPresent(AnyCodable.self, forKey: fallback)
    }
}
