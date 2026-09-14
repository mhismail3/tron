import Foundation

// These projections intentionally mirror packages/gateway/src/knowledge/
// knowledge-contract.ts. The Gateway owns all bytes and revisions; iOS only
// retains the currently presented page.
struct KnowledgePresentationIdentity: Equatable, Sendable {
    let profileID: String?
    let lifecycleGeneration: Int?
    let connectionID: Int?
}

enum KnowledgeScope: String, Codable, CaseIterable, Sendable { case personal, research
    var label: String { rawValue.capitalized }
}
enum KnowledgeRecordKind: String, Codable, CaseIterable, Sendable { case source, observation, note
    var label: String { rawValue.capitalized }
    var icon: String { switch self { case .source: "link"; case .observation: "eye"; case .note: "note.text" } }
}
enum KnowledgeSourceOriginKind: String, Codable, Sendable { case manual, connector, `import`, conversation }
enum KnowledgeCaptureDisposition: String, Codable, Sendable { case complete, partial, metadataOnly = "metadata-only", inaccessible, failed, referenceOnly = "reference-only" }
enum KnowledgeActor: String, Codable, Sendable { case user, agent, connector, `import`, system }
enum KnowledgeAttribution: String, Codable, Sendable { case user, assistant, tool, system, unknown }
enum KnowledgeCertainty: String, Codable, Sendable { case certain, qualified, uncertain }
enum KnowledgeNoteCertainty: String, Codable, Sendable { case confirmed, candidate, external, historical }
enum KnowledgeNoteRole: String, Codable, CaseIterable, Sendable { case fact, preference, concept, decision, workflow, synthesis }
enum KnowledgeRelationType: String, Codable, Sendable { case supports, contradicts, corrects, supersedes, derivedFrom, related }

struct KnowledgeObjectRef: Codable, Hashable, Sendable { let hash: String; let mediaType: String; let bytes: Int }
struct KnowledgeSessionEntryCitation: Codable, Hashable, Sendable {
    let sessionId: String; let branchId: String?; let entryId: String; let digest: String?; let startOffset: Int?; let endOffset: Int?
}
struct KnowledgeEvidenceRef: Codable, Hashable, Sendable {
    let recordId: String?; let revisionId: String?; let sessionEntry: KnowledgeSessionEntryCitation?; let objectHash: String?; let locator: String?
}
struct KnowledgeProvenance: Codable, Hashable, Sendable {
    let actor: KnowledgeActor; let source: String?; let sessionId: String?; let branchId: String?; let invocationId: String?; let evidence: [KnowledgeEvidenceRef]
}
struct KnowledgeTemporalQualification: Codable, Hashable, Sendable {
    let eventAt: String?; let validFrom: String?; let validTo: String?; let reviewDue: String?; let timezone: String?
}
struct KnowledgeRelation: Codable, Hashable, Sendable {
    let type: KnowledgeRelationType; let recordId: String; let revisionId: String?; let field: String?
}
struct KnowledgeSourceAnnotation: Codable, Hashable, Sendable { let text: String; let locator: String?; let createdAt: String? }
struct KnowledgeSourceIdentity: Codable, Hashable, Sendable { let provider: String; let accountId: String; let itemId: String }
struct KnowledgeSourceOrigin: Codable, Hashable, Sendable { let kind: KnowledgeSourceOriginKind; let capturedAt: String; let annotation: String?; let uri: String?; let identity: KnowledgeSourceIdentity? }
enum KnowledgeEvidenceQuality: String, Codable, Sendable { case high, medium, low, none }
enum KnowledgeFreshness: String, Codable, Sendable { case current, aging, stale, unknown }
struct KnowledgeSourceAssessment: Codable, Hashable, Sendable { let summary: String; let contribution: String?; let whyItMatters: String?; let evidenceQuality: KnowledgeEvidenceQuality; let freshness: KnowledgeFreshness; let possibleUse: String?; let generatedAt: String; let model: String? }
struct KnowledgeSourceRetention: Codable, Hashable, Sendable { let sensitivity: String; let usageConstraint: String?; let evidenceAvailable: Bool; let originalHash: String? }
struct KnowledgeSourceContent: Codable, Hashable, Sendable {
    let title: String; let uri: String?; let text: String?; let object: KnowledgeObjectRef?; let mediaType: String?
    let captureDisposition: KnowledgeCaptureDisposition; let annotations: [KnowledgeSourceAnnotation]?; let sourcePublishedAt: String?; let capturedAt: String; let origin: String?
    let origins: [KnowledgeSourceOrigin]?; let identity: KnowledgeSourceIdentity?; var retention: KnowledgeSourceRetention? = nil; let assessment: KnowledgeSourceAssessment?
}
struct KnowledgeObservationRange: Codable, Hashable, Sendable {
    let sessionId: String; let branchId: String?; let fromEntryId: String; let toEntryId: String; let entryIds: [String]; let entryDigest: String; let projectId: String?; let invocationIds: [String]?
}
struct KnowledgeObservationItem: Codable, Hashable, Sendable {
    let text: String; let attribution: KnowledgeAttribution; let observedAt: String; let certainty: KnowledgeCertainty; let evidence: [KnowledgeEvidenceRef]?; let field: String?
}
struct KnowledgeObservationContent: Codable, Hashable, Sendable { let range: KnowledgeObservationRange; let items: [KnowledgeObservationItem]; let observer: KnowledgeObserver? }
struct KnowledgeObserver: Codable, Hashable, Sendable { let model: String?; let promptVersion: String }
struct KnowledgeNoteFieldQualification: Codable, Hashable, Sendable {
    let field: String; let value: JSONValue; let subject: String?; let evidence: [KnowledgeEvidenceRef]; let certainty: KnowledgeNoteCertainty; let validFrom: String?; let validTo: String?
}
struct KnowledgeNoteContent: Codable, Hashable, Sendable { let title: String; let body: String?; let fields: [KnowledgeNoteFieldQualification]?; let role: KnowledgeNoteRole; let confirmed: Bool; let contraryEvidence: [KnowledgeEvidenceRef]?; let freshness: KnowledgeFreshness?; let privacyScope: String?; let usageConstraint: String? }

enum KnowledgeRecordContent: Codable, Hashable, Sendable {
    case source(KnowledgeSourceContent), observation(KnowledgeObservationContent), note(KnowledgeNoteContent)
    init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: ProbeKeys.self)
        if probe.contains(.range) { self = .observation(try KnowledgeObservationContent(from: decoder)) }
        else if probe.contains(.role) { self = .note(try KnowledgeNoteContent(from: decoder)) }
        else { self = .source(try KnowledgeSourceContent(from: decoder)) }
    }
    func encode(to encoder: Encoder) throws {
        switch self { case .source(let value): try value.encode(to: encoder); case .observation(let value): try value.encode(to: encoder); case .note(let value): try value.encode(to: encoder) }
    }
    private enum ProbeKeys: String, CodingKey { case range, role }
}
struct KnowledgeImportOrigin: Codable, Hashable, Sendable { let store: String; let recordId: String; let revision: String; let importedAt: String; let review: KnowledgeImportReview? }
struct KnowledgeImportReview: Codable, Hashable, Sendable { let batch: String?; let auditId: String?; let receiptId: String?; let resultRevision: String?; let basis: String? }
struct KnowledgeRecord: Codable, Hashable, Identifiable, Sendable {
    let schemaVersion: Int; let id: String; let revisionId: String; let kind: KnowledgeRecordKind; let scope: KnowledgeScope; let createdAt: String; let updatedAt: String
    let provenance: KnowledgeProvenance; let temporal: KnowledgeTemporalQualification?; let relations: [KnowledgeRelation]; var importOrigin: KnowledgeImportOrigin? = nil; let content: KnowledgeRecordContent
}
struct KnowledgeRecordDraft: Codable, Hashable, Sendable {
    let id: String?; let createdAt: String?; let updatedAt: String?; let kind: KnowledgeRecordKind; let scope: KnowledgeScope; let provenance: KnowledgeProvenance; let temporal: KnowledgeTemporalQualification?; let relations: [KnowledgeRelation]; var importOrigin: KnowledgeImportOrigin? = nil; let content: KnowledgeRecordContent
}

struct KnowledgeEligibility: Codable, Hashable, Sendable { var sessionIds: [String]; var projectIds: [String]; var excludedSessionIds: [String]; var excludedProjectIds: [String] }
struct KnowledgeObservationLimits: Codable, Hashable, Sendable { var enabled: Bool; var model: String?; var maxInputChars: Int; var maxOutputChars: Int; var timeoutMs: Int; var maxAttempts: Int }
struct KnowledgeConfig: Codable, Hashable, Sendable {
    let schemaVersion: Int; var revision: Int; var eligibility: KnowledgeEligibility; var observation: KnowledgeObservationLimits; var maximumSearchResults: Int; var currentInterests: [String]
}
struct KnowledgeStatus: Codable, Hashable, Sendable {
    let available: Bool; let state: String; let stateRevision: Int?; let recordCount: Int; let coverageCount: Int; let suppressedCount: Int; let pendingCleanupCount: Int; let config: KnowledgeConfig; let observationConfigured: Bool; let detail: String?
}
struct KnowledgeListResponse: Codable, Hashable, Sendable { let records: [KnowledgeRecord]; let nextCursor: String?; let stateRevision: Int }
struct KnowledgeSearchHit: Codable, Hashable, Sendable { let record: KnowledgeRecord; let score: Double; let matchedFields: [String] }
struct KnowledgeSearchResponse: Codable, Hashable, Sendable { let hits: [KnowledgeSearchHit]; let stateRevision: Int; let indexState: String }
struct KnowledgeRecallResponse: Codable, Hashable, Sendable { let records: [KnowledgeRecord]; let citations: [KnowledgeEvidenceRef]; let stateRevision: Int; let availability: String }
struct KnowledgeMutationResult: Codable, Hashable, Sendable { let record: KnowledgeRecord; let stateRevision: Int }
/// URL capture is owned by the Gateway source adapter and therefore returns
/// capture metadata rather than the generic record-mutation envelope.
struct KnowledgeSourceCaptureResult: Codable, Hashable, Sendable { let record: KnowledgeRecord; let duplicate: Bool; let fetched: Bool; let assessmentError: String? }
struct KnowledgeForgetResult: Codable, Hashable, Sendable { let forgotten: Bool; let recordId: String; let stateRevision: Int }
struct KnowledgeExclusionResult: Codable, Hashable, Sendable { let recordId: String; let excluded: Bool; let stateRevision: Int }
struct KnowledgeConnectorStatus: Codable, Hashable, Sendable {
    let connector: String; let configured: Bool; let enabled: Bool; let health: String; let accountId: String?; let scope: String?; let lastRunAt: String?; let lastError: String?; let remaining: Int; let pending: Int; let paidBudgetCents: Int; let allowWrites: Bool; let recurringApproved: Bool; let paidAccessApproved: Bool
    var available: Bool { true }
    var writesEnabled: Bool { allowWrites }
    var state: String { health }
    var detail: String? { lastError }
}
struct KnowledgeConnectorRunResult: Codable, Hashable, Sendable { let dryRun: Bool; let connector: String; let discovered: Int; let captured: Int?; let pending: Int; let remaining: Int?; let health: String; let partial: Int?; let error: String? }
struct KnowledgeImportPlan: Codable, Hashable, Sendable { let operation: String; let source: String; let planHash: String; let planned: Int; let selected: Int; let imported: Int; let resumed: Int; let skipped: Int; let failed: Int; let completed: Bool; let progress: KnowledgeImportProgress; let mappings: [KnowledgeImportMapping]; let warnings: [String] }
struct KnowledgeImportProgress: Codable, Hashable, Sendable { let completed: Int; let remaining: Int; let total: Int }
struct KnowledgeImportMapping: Codable, Hashable, Sendable { let legacyId: String; let kind: String; let newId: String }
struct KnowledgeImportResult: Codable, Hashable, Sendable { let operation: String; let source: String; let planHash: String; let planned: Int; let selected: Int; let imported: Int; let resumed: Int; let skipped: Int; let failed: Int; let completed: Bool; let progress: KnowledgeImportProgress; let mappings: [KnowledgeImportMapping]; let warnings: [String] }
struct KnowledgeTriageResult: Codable, Hashable, Sendable { let source: KnowledgeRecord; let assessment: KnowledgeSourceAssessment }

struct KnowledgeListRequest: Encodable, Sendable { let kind: KnowledgeRecordKind?; let scope: KnowledgeScope?; let includeSuppressed: Bool; let cursor: String?; let limit: Int }
struct KnowledgeSearchRequest: Encodable, Sendable { let query: String; let kind: KnowledgeRecordKind?; let scope: KnowledgeScope?; let limit: Int }
struct KnowledgeRecallRequest: Encodable, Sendable { let query: String?; let sessionId: String?; let entryId: String?; let scope: KnowledgeScope?; let limit: Int }

extension KnowledgeRecord {
    var title: String {
        switch content { case .source(let c): c.title; case .observation: "Observation"; case .note(let c): c.title }
    }
    var summary: String {
        switch content { case .source(let c): c.text ?? c.uri ?? c.captureDisposition.rawValue; case .observation(let c): c.items.map { $0.text }.joined(separator: " "); case .note(let c): c.body ?? "" }
    }
}
