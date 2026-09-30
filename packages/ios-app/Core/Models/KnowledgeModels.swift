import Foundation
import CryptoKit

// These projections intentionally mirror packages/gateway/src/knowledge/
// knowledge-contract.ts. The Gateway owns all bytes and revisions; iOS only
// retains the currently presented page.
package struct KnowledgePresentationIdentity: Equatable, Sendable {
    package let profileID: String?
    package let lifecycleGeneration: Int?
    package let connectionID: Int?

    package init(profileID: String?, lifecycleGeneration: Int?, connectionID: Int?) {
        self.profileID = profileID
        self.lifecycleGeneration = lifecycleGeneration
        self.connectionID = connectionID
    }
}

package enum KnowledgeSourceAssessor: String, Codable, Sendable { case jev, model }
package enum KnowledgeScope: String, Codable, CaseIterable, Sendable { case personal, research
    package var label: String { self == .personal ? "Personal" : "Research" }
}
package enum KnowledgeRecordKind: String, Codable, CaseIterable, Sendable { case source, observation, note
    package var label: String { rawValue.capitalized }
    package var icon: String { switch self { case .source: "link"; case .observation: "eye"; case .note: "note.text" } }
}
enum KnowledgeSourceOriginKind: String, Codable, Sendable { case manual, connector, `import`, conversation }
package enum KnowledgeCaptureDisposition: String, Codable, Sendable { case complete, partial, metadataOnly = "metadata-only", inaccessible, failed, referenceOnly = "reference-only" }
package enum KnowledgeActor: String, Codable, Sendable { case user, agent, connector, `import`, system }
package enum KnowledgeAttribution: String, Codable, Sendable { case user, assistant, tool, system, unknown }
package enum KnowledgeCertainty: String, Codable, Sendable { case certain, qualified, uncertain }
package enum KnowledgeNoteCertainty: String, Codable, Sendable { case confirmed, candidate, external, historical }
package enum KnowledgeNoteRole: String, Codable, CaseIterable, Sendable { case fact, preference, concept, decision, workflow, synthesis }
package enum KnowledgeRelationType: String, Codable, Sendable { case supports, contradicts, corrects, supersedes, derivedFrom, related }

package struct KnowledgeObjectRef: Codable, Hashable, Sendable { package let hash: String; package let mediaType: String; package let bytes: Int }
enum KnowledgeSourceRepresentationKind: String, Codable, Hashable, Sendable { case providerAPI = "provider-api"; case linkedArticle = "linked-article" }
struct KnowledgeSourceRepresentation: Codable, Hashable, Sendable { let kind: KnowledgeSourceRepresentationKind; let object: KnowledgeObjectRef; let mediaType: String? }
package struct KnowledgeObjectRead: Codable, Hashable, Sendable { package let hash: String; package let mediaType: String; package let bytes: Int; package let totalBytes: Int?; package let offset: Int?; package let nextOffset: Int?; package let base64: String }
package enum KnowledgeCoverageDisposition: String, Codable, Hashable, Sendable { case observed, empty, excluded, pending, failed, unavailable }
package struct KnowledgeCoverageSummary: Codable, Hashable, Sendable {
    package let observedCount: Int; package let emptyCount: Int; package let excludedCount: Int; package let pendingCount: Int; package let failedCount: Int; package let unavailableCount: Int; package let remainingCount: Int
}
package struct KnowledgeObservationCoverage: Codable, Hashable, Sendable, Identifiable {
    let schemaVersion: Int; package let id: String; package let revisionId: String; package let range: KnowledgeObservationRange
    package let disposition: KnowledgeCoverageDisposition; let groupRevisionIds: [String]; let recordedAt: String; package let reason: String?
}
package struct KnowledgeCoverageDismissResult: Codable, Sendable {
    package let coverage: KnowledgeObservationCoverage
    let stateRevision: Int
}
package struct KnowledgeCoveragePage: Codable, Hashable, Sendable {
    package let coverage: [KnowledgeObservationCoverage]; package let stateRevision: Int; package let nextCursor: String?
}

package struct KnowledgeSessionEntryCitation: Codable, Hashable, Sendable {
    package let sessionId: String; let branchId: String?; package let entryId: String; let digest: String?; let startOffset: Int?; let endOffset: Int?
}
package struct KnowledgeEvidenceRef: Codable, Hashable, Sendable {
    package let recordId: String?; package let revisionId: String?; package let sessionEntry: KnowledgeSessionEntryCitation?; package let objectHash: String?; package let locator: String?

    package init(recordId: String?, revisionId: String?, sessionEntry: KnowledgeSessionEntryCitation?, objectHash: String?, locator: String?) {
        self.recordId = recordId
        self.revisionId = revisionId
        self.sessionEntry = sessionEntry
        self.objectHash = objectHash
        self.locator = locator
    }
}
package struct KnowledgeProvenance: Codable, Hashable, Sendable {
    package let actor: KnowledgeActor; let source: String?; let sessionId: String?; let branchId: String?; let invocationId: String?; package let evidence: [KnowledgeEvidenceRef]

    package init(actor: KnowledgeActor, source: String?, sessionId: String?, branchId: String?, invocationId: String?, evidence: [KnowledgeEvidenceRef]) {
        self.actor = actor; self.source = source; self.sessionId = sessionId; self.branchId = branchId
        self.invocationId = invocationId; self.evidence = evidence
    }
}
package struct KnowledgeTemporalQualification: Codable, Hashable, Sendable {
    package let eventAt: String?; package let validFrom: String?; package let validTo: String?; package let reviewDue: String?; let timezone: String?
}
package struct KnowledgeRelation: Codable, Hashable, Sendable {
    let type: KnowledgeRelationType; package let recordId: String; let revisionId: String?; let field: String?

    package init(type: KnowledgeRelationType, recordId: String, revisionId: String?, field: String?) {
        self.type = type
        self.recordId = recordId
        self.revisionId = revisionId
        self.field = field
    }
}
package struct KnowledgeSourceAnnotation: Codable, Hashable, Sendable { package let text: String; let locator: String?; let createdAt: String? }
package struct KnowledgeSourceIdentity: Codable, Hashable, Sendable { package let provider: String; let accountId: String; package let itemId: String }
struct KnowledgeSourceOrigin: Codable, Hashable, Sendable { let kind: KnowledgeSourceOriginKind; let capturedAt: String; let annotation: String?; let uri: String?; let identity: KnowledgeSourceIdentity? }
enum KnowledgeEvidenceQuality: String, Codable, Sendable { case high, medium, low, none, unknown }
package enum KnowledgeFreshness: String, Codable, Sendable { case current, aging, stale, unknown }
package enum KnowledgeSourceFreshness: String, Codable, Sendable { case fresh, aging, stale, unknown }
package enum KnowledgeSourceAgeBasis: String, Codable, Sendable { case sourceSavedAt, capturedAt }
package enum KnowledgeSourceVerdict: String, Codable, CaseIterable, Sendable { case evergreen, dated, superseded, archive
    package var label: String { switch self { case .evergreen: "Evergreen"; case .dated: "Dated but useful"; case .superseded: "Superseded"; case .archive: "Archive" } }
}
package struct KnowledgeTagLabel: Codable, Hashable, Sendable, Identifiable { package let id: String; package let label: String; package let category: String?; package let decayClass: String?; package let state: String? }
package struct KnowledgeTagDefinition: Codable, Hashable, Sendable, Identifiable { package let id: String; package let label: String; package let definition: String; package let category: String; package let decayClass: String; package let state: String; package let mergedInto: String? }
package struct KnowledgeTagVocabulary: Codable, Hashable, Sendable { package let revision: Int; package let tags: [KnowledgeTagDefinition]; package let guidelines: String }
package enum KnowledgeSourceAdmission: String, Codable, Hashable, Sendable { case pending, retained, archived }
package struct KnowledgeSourceSummary: Codable, Hashable, Sendable {
    let text: String; let generatedAt: String; let sourceRevisionId: String; let evidenceDigest: String; package let coverage: String
}
package struct KnowledgeSourceTake: Codable, Hashable, Sendable { package let text: String; package let confirmed: Bool; package let updatedAt: String }
package struct KnowledgeSourceVerdictState: Codable, Hashable, Sendable { package let verdict: KnowledgeSourceVerdict; package let supersededBy: String?; package let reason: String?; package let decidedAt: String }
package struct KnowledgeSourceTagSelection: Codable, Hashable, Sendable { package let tagIds: [String]; package let vocabularyRevision: Int; package let inputsDigest: String; package let assignedAt: String }
package struct KnowledgeCurationJob: Codable, Hashable, Sendable, Identifiable { package var id: String { commandId }; package let commandId: String; package let operation: String; package let sourceId: String; package let status: String; package let startedAt: String; package let finishedAt: String?; package let revisionId: String?; package let code: String?; package let reason: String? }
package struct KnowledgeCurationJobsResponse: Codable, Hashable, Sendable { package let jobs: [KnowledgeCurationJob]; package let running: Int; package let failed: Int }
package struct KnowledgeCurationOutcome: Codable, Hashable, Sendable { package let recordId: String; package let status: String; package let revisionId: String?; package let currentRevision: String?; package let code: String?; package let reason: String? }
package struct KnowledgeCurationResponse: Codable, Hashable, Sendable { package let commandId: String; package let operation: String; package let applied: Int; package let outcomes: [KnowledgeCurationOutcome]; package let stateRevision: Int }
package struct KnowledgeSourceSummaryStart: Codable, Hashable, Sendable { package let job: KnowledgeCurationJob; package let record: KnowledgeRecord }
struct KnowledgeSourceAssessmentUsage: Codable, Hashable, Sendable {
    // Assessment pricing may be a fraction of one cent; match the Gateway number contract.
    let inputTokens: Int; let outputTokens: Int; let estimatedCostCents: Double; let pricing: String
}
package struct KnowledgeSourceAssessment: Codable, Hashable, Sendable {
    let summary: String; let contribution: String?; let whyItMatters: String?; let evidenceQuality: KnowledgeEvidenceQuality; package let freshness: KnowledgeFreshness; let possibleUse: String?; let generatedAt: String; let model: String?; package let recommendation: KnowledgeSourceAdmission?; let confidence: Double?; let profileVersion: String?; let rubricVersion: String?
    // These fields are provider assessment metadata, not capture completeness or epistemic confidence.
    let inputDigest: String?; let evidenceDigest: String?; let assessmentInputDigest: String?; let coverage: String?; package let classification: String?; let usage: KnowledgeSourceAssessmentUsage?
    init(summary: String, contribution: String?, whyItMatters: String?, evidenceQuality: KnowledgeEvidenceQuality, freshness: KnowledgeFreshness, possibleUse: String?, generatedAt: String, model: String?, recommendation: KnowledgeSourceAdmission? = nil, confidence: Double? = nil, profileVersion: String? = nil, rubricVersion: String? = nil, inputDigest: String? = nil, evidenceDigest: String? = nil, assessmentInputDigest: String? = nil, coverage: String? = nil, classification: String? = nil, usage: KnowledgeSourceAssessmentUsage? = nil) {
        self.summary = summary; self.contribution = contribution; self.whyItMatters = whyItMatters; self.evidenceQuality = evidenceQuality; self.freshness = freshness; self.possibleUse = possibleUse; self.generatedAt = generatedAt; self.model = model; self.recommendation = recommendation; self.confidence = confidence; self.profileVersion = profileVersion; self.rubricVersion = rubricVersion; self.inputDigest = inputDigest; self.evidenceDigest = evidenceDigest; self.assessmentInputDigest = assessmentInputDigest; self.coverage = coverage; self.classification = classification; self.usage = usage
    }
    private enum CodingKeys: String, CodingKey { case summary, contribution, whyItMatters, evidenceQuality, freshness, possibleUse, generatedAt, model, recommendation, confidence, profileVersion, rubricVersion, inputDigest, evidenceDigest, assessmentInputDigest, coverage, classification, usage }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary); contribution = try c.decodeIfPresent(String.self, forKey: .contribution); whyItMatters = try c.decodeIfPresent(String.self, forKey: .whyItMatters)
        evidenceQuality = try c.decode(KnowledgeEvidenceQuality.self, forKey: .evidenceQuality); freshness = try c.decode(KnowledgeFreshness.self, forKey: .freshness); possibleUse = try c.decodeIfPresent(String.self, forKey: .possibleUse); generatedAt = try c.decode(String.self, forKey: .generatedAt); model = try c.decodeIfPresent(String.self, forKey: .model)
        recommendation = try c.decodeIfPresent(KnowledgeSourceAdmission.self, forKey: .recommendation); confidence = try c.decodeIfPresent(Double.self, forKey: .confidence); profileVersion = try c.decodeIfPresent(String.self, forKey: .profileVersion); rubricVersion = try c.decodeIfPresent(String.self, forKey: .rubricVersion)
        inputDigest = try c.decodeIfPresent(String.self, forKey: .inputDigest); evidenceDigest = try c.decodeIfPresent(String.self, forKey: .evidenceDigest); assessmentInputDigest = try c.decodeIfPresent(String.self, forKey: .assessmentInputDigest); coverage = try c.decodeIfPresent(String.self, forKey: .coverage); classification = try c.decodeIfPresent(String.self, forKey: .classification); usage = try c.decodeIfPresent(KnowledgeSourceAssessmentUsage.self, forKey: .usage)
    }
}
package struct KnowledgeSourceAdmissionState: Codable, Hashable, Sendable { package let status: KnowledgeSourceAdmission; let reason: String?; let decidedAt: String; let profileVersion: String?; let rubricVersion: String? }
struct KnowledgeSourceRetention: Codable, Hashable, Sendable { let sensitivity: String; let usageConstraint: String?; let evidenceAvailable: Bool; let originalHash: String? }
package struct KnowledgeSourceContent: Codable, Hashable, Sendable {
    package let title: String; package let uri: String?; var collectionId: String?; package let text: String?; let object: KnowledgeObjectRef?; package let preview: KnowledgeObjectRef?; var representations: [KnowledgeSourceRepresentation]?; package let mediaType: String?; package let linkedUrls: [String]?
    package let captureDisposition: KnowledgeCaptureDisposition; package let captureReason: String?; package let annotations: [KnowledgeSourceAnnotation]?; let sourcePublishedAt: String?; package let sourceSavedAt: String?; package let capturedAt: String; package let origin: String?
    let origins: [KnowledgeSourceOrigin]?; package let identity: KnowledgeSourceIdentity?; var retention: KnowledgeSourceRetention?; package let assessment: KnowledgeSourceAssessment?; package let summary: KnowledgeSourceSummary?; package let take: KnowledgeSourceTake?; package let tags: KnowledgeSourceTagSelection?; package let verdict: KnowledgeSourceVerdictState?; package var admission: KnowledgeSourceAdmissionState?
    init(title: String, uri: String?, collectionId: String? = nil, text: String?, object: KnowledgeObjectRef?, preview: KnowledgeObjectRef? = nil, representations: [KnowledgeSourceRepresentation]? = nil, mediaType: String?, linkedUrls: [String]? = nil, captureDisposition: KnowledgeCaptureDisposition, captureReason: String? = nil, annotations: [KnowledgeSourceAnnotation]?, sourcePublishedAt: String?, sourceSavedAt: String? = nil, capturedAt: String, origin: String?, origins: [KnowledgeSourceOrigin]?, identity: KnowledgeSourceIdentity?, retention: KnowledgeSourceRetention? = nil, assessment: KnowledgeSourceAssessment?, contentSummary: KnowledgeSourceSummary? = nil, admission: KnowledgeSourceAdmissionState? = nil, take: KnowledgeSourceTake? = nil, tags: KnowledgeSourceTagSelection? = nil, verdict: KnowledgeSourceVerdictState? = nil) {
        self.title = title; self.uri = uri; self.collectionId = collectionId; self.text = text; self.object = object; self.preview = preview; self.representations = representations; self.mediaType = mediaType; self.linkedUrls = linkedUrls; self.captureDisposition = captureDisposition; self.captureReason = captureReason; self.annotations = annotations; self.sourcePublishedAt = sourcePublishedAt; self.sourceSavedAt = sourceSavedAt; self.capturedAt = capturedAt; self.origin = origin; self.origins = origins; self.identity = identity; self.retention = retention; self.assessment = assessment; self.summary = contentSummary; self.take = take; self.tags = tags; self.verdict = verdict; self.admission = admission
    }
    private enum CodingKeys: String, CodingKey { case title, uri, collectionId, text, object, preview, representations, mediaType, linkedUrls, captureDisposition, captureReason, annotations, sourcePublishedAt, sourceSavedAt, capturedAt, origin, origins, identity, retention, assessment, summary, take, tags, verdict, admission }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title); uri = try c.decodeIfPresent(String.self, forKey: .uri); collectionId = try c.decodeIfPresent(String.self, forKey: .collectionId); text = try c.decodeIfPresent(String.self, forKey: .text); object = try c.decodeIfPresent(KnowledgeObjectRef.self, forKey: .object); preview = try c.decodeIfPresent(KnowledgeObjectRef.self, forKey: .preview); representations = try c.decodeIfPresent([KnowledgeSourceRepresentation].self, forKey: .representations); mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType); linkedUrls = try c.decodeIfPresent([String].self, forKey: .linkedUrls)
        captureDisposition = try c.decode(KnowledgeCaptureDisposition.self, forKey: .captureDisposition); captureReason = try c.decodeIfPresent(String.self, forKey: .captureReason); annotations = try c.decodeIfPresent([KnowledgeSourceAnnotation].self, forKey: .annotations); sourcePublishedAt = try c.decodeIfPresent(String.self, forKey: .sourcePublishedAt); sourceSavedAt = try c.decodeIfPresent(String.self, forKey: .sourceSavedAt); capturedAt = try c.decode(String.self, forKey: .capturedAt); origin = try c.decodeIfPresent(String.self, forKey: .origin)
        origins = try c.decodeIfPresent([KnowledgeSourceOrigin].self, forKey: .origins); identity = try c.decodeIfPresent(KnowledgeSourceIdentity.self, forKey: .identity); retention = try c.decodeIfPresent(KnowledgeSourceRetention.self, forKey: .retention); assessment = try c.decodeIfPresent(KnowledgeSourceAssessment.self, forKey: .assessment); summary = try c.decodeIfPresent(KnowledgeSourceSummary.self, forKey: .summary); take = try c.decodeIfPresent(KnowledgeSourceTake.self, forKey: .take); tags = try c.decodeIfPresent(KnowledgeSourceTagSelection.self, forKey: .tags); verdict = try c.decodeIfPresent(KnowledgeSourceVerdictState.self, forKey: .verdict); admission = try c.decodeIfPresent(KnowledgeSourceAdmissionState.self, forKey: .admission)
    }
}
package struct KnowledgeObservationRange: Codable, Hashable, Sendable {
    package let sessionId: String; package let branchId: String?; package let fromEntryId: String; package let toEntryId: String; package let entryIds: [String]; package let entryDigest: String; package let projectId: String?; package let invocationIds: [String]?
}
package struct KnowledgeObservationItem: Codable, Hashable, Sendable {
    package let text: String; package let attribution: KnowledgeAttribution; package let observedAt: String; package let certainty: KnowledgeCertainty; package let evidence: [KnowledgeEvidenceRef]?; let field: String?
}
package struct KnowledgeObservationContent: Codable, Hashable, Sendable { package let range: KnowledgeObservationRange; package let items: [KnowledgeObservationItem]; package let observer: KnowledgeObserver? }
package struct KnowledgeObserver: Codable, Hashable, Sendable { package let model: String?; package let promptVersion: String }
package struct KnowledgeNoteFieldQualification: Codable, Hashable, Sendable {
    package let field: String; package let value: JSONValue; package let subject: String?; package let evidence: [KnowledgeEvidenceRef]; package let certainty: KnowledgeNoteCertainty; package let validFrom: String?; package let validTo: String?
}
package struct KnowledgeNoteContent: Codable, Hashable, Sendable {
    package let title: String; package let body: String?; package let fields: [KnowledgeNoteFieldQualification]?; package let role: KnowledgeNoteRole; package let confirmed: Bool; package let contraryEvidence: [KnowledgeEvidenceRef]?; package let freshness: KnowledgeFreshness?; package let privacyScope: String?; package let usageConstraint: String?

    package init(title: String, body: String?, fields: [KnowledgeNoteFieldQualification]?, role: KnowledgeNoteRole, confirmed: Bool, contraryEvidence: [KnowledgeEvidenceRef]?, freshness: KnowledgeFreshness?, privacyScope: String?, usageConstraint: String?) {
        self.title = title; self.body = body; self.fields = fields; self.role = role; self.confirmed = confirmed
        self.contraryEvidence = contraryEvidence; self.freshness = freshness; self.privacyScope = privacyScope; self.usageConstraint = usageConstraint
    }
}

package enum KnowledgeRecordContent: Codable, Hashable, Sendable {
    case source(KnowledgeSourceContent), observation(KnowledgeObservationContent), note(KnowledgeNoteContent)
    package init(from decoder: Decoder) throws {
        let probe = try decoder.container(keyedBy: ProbeKeys.self)
        if probe.contains(.range) { self = .observation(try KnowledgeObservationContent(from: decoder)) }
        else if probe.contains(.role) { self = .note(try KnowledgeNoteContent(from: decoder)) }
        else { self = .source(try KnowledgeSourceContent(from: decoder)) }
    }
    package func encode(to encoder: Encoder) throws {
        switch self { case .source(let value): try value.encode(to: encoder); case .observation(let value): try value.encode(to: encoder); case .note(let value): try value.encode(to: encoder) }
    }
    private enum ProbeKeys: String, CodingKey { case range, role }
}
extension KnowledgeRecordContent {
    package var sourcePreviewHash: String? { if case .source(let source) = self { return source.preview?.hash }; return nil }
}
struct KnowledgeImportReview: Codable, Hashable, Sendable { let batch: String?; let auditId: String?; let receiptId: String?; let resultRevision: String?; let basis: String? }
package struct KnowledgeRecord: Codable, Hashable, Identifiable, Sendable {
    let schemaVersion: Int; package let id: String; package let revisionId: String; package let kind: KnowledgeRecordKind; package let scope: KnowledgeScope; package let createdAt: String; package let updatedAt: String
    package let provenance: KnowledgeProvenance; package let temporal: KnowledgeTemporalQualification?; package let relations: [KnowledgeRelation]; package let content: KnowledgeRecordContent
}
package struct KnowledgeRecordDraft: Codable, Hashable, Sendable {
    let id: String?; let createdAt: String?; let updatedAt: String?; let kind: KnowledgeRecordKind; let scope: KnowledgeScope; let provenance: KnowledgeProvenance; let temporal: KnowledgeTemporalQualification?; let relations: [KnowledgeRelation]; let content: KnowledgeRecordContent

    package init(id: String?, createdAt: String?, updatedAt: String?, kind: KnowledgeRecordKind, scope: KnowledgeScope, provenance: KnowledgeProvenance, temporal: KnowledgeTemporalQualification?, relations: [KnowledgeRelation], content: KnowledgeRecordContent) {
        self.id = id; self.createdAt = createdAt; self.updatedAt = updatedAt; self.kind = kind; self.scope = scope
        self.provenance = provenance; self.temporal = temporal; self.relations = relations; self.content = content
    }
}

package struct KnowledgeEligibility: Codable, Hashable, Sendable {
    // Only an explicit true grants global scope. Omission retains the selected
    // sessions/projects, including the intentionally empty initial selection.
    package var allSessions: Bool?
    var sessionIds: [String]; var projectIds: [String]; var excludedSessionIds: [String]; var excludedProjectIds: [String]
}
package struct KnowledgeObservationLimits: Codable, Hashable, Sendable { package var enabled: Bool; package var model: String?; var maxInputChars: Int; var maxOutputChars: Int; var timeoutMs: Int; var maxAttempts: Int }

package enum KnowledgeObservationConfigurationPolicy {
    package static func admitsEnable(hasModel: Bool, supportsGlobalObservation: Bool) -> Bool {
        hasModel && supportsGlobalObservation
    }

    package static func applyingGlobalGrant(_ config: KnowledgeConfig, enabled: Bool) -> KnowledgeConfig {
        var next = config
        next.observation.enabled = enabled
        if enabled { next.eligibility.allSessions = true }
        return next
    }
}

package struct KnowledgeModel: Codable, Hashable, Sendable {
    package var model: String?
    package var maxInputChars: Int
    package var maxOutputChars: Int
    package init(model: String?, maxInputChars: Int = 48_000, maxOutputChars: Int = 8_000) {
        self.model = model; self.maxInputChars = maxInputChars; self.maxOutputChars = maxOutputChars
    }
}
package struct KnowledgeConfig: Codable, Hashable, Sendable {
    let schemaVersion: Int; var revision: Int; package var eligibility: KnowledgeEligibility; package var observation: KnowledgeObservationLimits; package var knowledgeModel: KnowledgeModel? = nil; var maximumSearchResults: Int; package var currentInterests: [String]; package var tagVocabulary: KnowledgeTagVocabulary
}
package struct KnowledgeStatus: Codable, Hashable, Sendable {
    let available: Bool; let state: String; package let stateRevision: Int?; package let recordCount: Int; package let coverageCount: Int; package let coverage: KnowledgeCoverageSummary; package let suppressedCount: Int; package let pendingCleanupCount: Int; package let config: KnowledgeConfig; let observationConfigured: Bool; let detail: String?
}

/// A committed Knowledge mutation broadcast. The revision is what a presented
/// catalogue page compares against before refreshing, and the ids let it patch
/// the affected rows instead of replacing the page.
package struct KnowledgeChanged: Decodable, Hashable, Sendable {
    package let stateRevision: Int
    package let recordIds: [String]?

    private enum CodingKeys: String, CodingKey { case stateRevision, recordIds }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stateRevision = try values.decode(Int.self, forKey: .stateRevision)
        let ids = try values.decodeIfPresent([String].self, forKey: .recordIds)
        guard stateRevision >= 0,
              ids.map({ $0.count <= KnowledgeChangeGating.maximumRecordIDs && $0.allSatisfy { !$0.isEmpty } }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .stateRevision, in: values, debugDescription: "Invalid knowledge change revision")
        }
        // An empty id list cannot name rows; the mutation revision alone is the
        // signal, so the consumer refreshes its first page instead.
        recordIds = ids.flatMap { $0.isEmpty ? nil : $0 }
    }
}
package struct KnowledgeListResponse: Codable, Hashable, Sendable {
    package let records: [KnowledgeRecord]; package let nextCursor: String?; package let stateRevision: Int

    package init(records: [KnowledgeRecord], nextCursor: String?, stateRevision: Int) {
        self.records = records
        self.nextCursor = nextCursor
        self.stateRevision = stateRevision
    }
}
package struct KnowledgeSearchHit: Codable, Hashable, Sendable { package let record: KnowledgeRecord; let score: Double; let matchedFields: [String] }
package struct KnowledgeSearchResponse: Codable, Hashable, Sendable { package let hits: [KnowledgeSearchHit]; package let stateRevision: Int; package let indexState: String }
package struct KnowledgeRecallResponse: Codable, Hashable, Sendable { package let records: [KnowledgeRecord]; let citations: [KnowledgeEvidenceRef]; let stateRevision: Int; let availability: String }
package struct KnowledgeMutationResult: Codable, Hashable, Sendable { package let record: KnowledgeRecord; let stateRevision: Int }
/// URL capture is owned by the Gateway source adapter and therefore returns
/// capture metadata rather than the generic record-mutation envelope.
package struct KnowledgeSourceCaptureResult: Codable, Hashable, Sendable { let record: KnowledgeRecord; let duplicate: Bool; let fetched: Bool; let assessmentError: String? }
package struct KnowledgeForgetResult: Codable, Hashable, Sendable { let forgotten: Bool; let recordId: String; let stateRevision: Int }
package struct KnowledgeExclusionResult: Codable, Hashable, Sendable { let recordId: String; let excluded: Bool; let stateRevision: Int }
package struct KnowledgeSourceAssessmentResult: Codable, Hashable, Sendable { package let source: KnowledgeRecord; package let assessment: KnowledgeSourceAssessment }

package struct KnowledgeListRequest: Encodable, Sendable {
    let kind: KnowledgeRecordKind?; let scope: KnowledgeScope?; let includeSuppressed: Bool; let includeArchived: Bool?; let includePending: Bool?; let sourceAdmission: KnowledgeSourceAdmission?; let cursor: String?; let limit: Int

    package init(kind: KnowledgeRecordKind?, scope: KnowledgeScope?, includeSuppressed: Bool, includeArchived: Bool?, includePending: Bool?, sourceAdmission: KnowledgeSourceAdmission?, cursor: String?, limit: Int) {
        self.kind = kind
        self.scope = scope
        self.includeSuppressed = includeSuppressed
        self.includeArchived = includeArchived
        self.includePending = includePending
        self.sourceAdmission = sourceAdmission
        self.cursor = cursor
        self.limit = limit
    }
}
package struct KnowledgeSearchRequest: Encodable, Sendable {
    let query: String; let kind: KnowledgeRecordKind?; let scope: KnowledgeScope?; let includeArchived: Bool?; let includePending: Bool?; let sourceAdmission: KnowledgeSourceAdmission?; let limit: Int

    package init(query: String, kind: KnowledgeRecordKind?, scope: KnowledgeScope?, includeArchived: Bool?, includePending: Bool?, sourceAdmission: KnowledgeSourceAdmission?, limit: Int) {
        self.query = query
        self.kind = kind
        self.scope = scope
        self.includeArchived = includeArchived
        self.includePending = includePending
        self.sourceAdmission = sourceAdmission
        self.limit = limit
    }
}
package struct KnowledgeRecallRequest: Encodable, Sendable {
    let query: String?; let sessionId: String?; let entryId: String?; let scope: KnowledgeScope?; let limit: Int

    package init(query: String?, sessionId: String?, entryId: String?, scope: KnowledgeScope?, limit: Int) {
        self.query = query
        self.sessionId = sessionId
        self.entryId = entryId
        self.scope = scope
        self.limit = limit
    }
}

extension KnowledgeRecord {
    package var title: String {
        switch content { case .source(let c): c.title; case .observation: "Observation"; case .note(let c): c.title }
    }
    package var summary: String {
        switch content { case .source(let c): KnowledgeSourcePresentationPolicy.summary(c) ?? ""; case .observation(let c): c.items.map { $0.text }.joined(separator: " "); case .note(let c): c.body ?? "" }
    }
}

/// Presentation-only source semantics. Capture coverage, intake admission, and
/// assessment quality remain separate so a partial/reference source is never
/// presented as complete text or as a confidence score.
package enum KnowledgeSourcePresentationPolicy {
    package static func safeURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    package static func domain(_ value: String?) -> String? { safeURL(value)?.host?.lowercased() }

    /// Connector captures retain the requested URL alongside the resolved page URL.
    /// Prefer the latest origin for this exact saved item; unrelated referral origins
    /// must never redirect the source's Open original action.
    package static func originalURL(_ source: KnowledgeSourceContent) -> URL? {
        if let identity = source.identity,
           let requested = source.origins?.reversed().first(where: { origin in
               origin.identity == identity && origin.uri != nil && origin.uri != source.uri
           })?.uri {
            return safeURL(requested)
        }
        return safeURL(source.uri)
    }

    package static func publishedAt(_ source: KnowledgeSourceContent) -> String? {
        // Earlier Raindrop intake incorrectly stored its `created` (bookmark-save)
        // timestamp as publication time. Do not repeat that claim on old records.
        guard source.identity?.provider.lowercased() != "raindrop" else { return nil }
        return source.sourcePublishedAt
    }

    package static func summary(_ source: KnowledgeSourceContent) -> String? {
        guard let summary = source.summary else { return nil }
        let value = summary.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, summary.evidenceDigest == evidenceDigest(title: source.title, text: source.text ?? "") else { return nil }
        return value
    }

    static func evidenceDigest(title: String, text: String) -> String {
        func jsonString(_ value: String) -> String {
            let encoder = JSONEncoder()
            // Match Gateway JSON.stringify: Foundation otherwise escapes URL slashes.
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(data: (try? encoder.encode(value)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        }
        let canonical = "{\"title\":\(jsonString(title)),\"text\":\(jsonString(text))}"
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The shared row/type rule, usable from either a full source or the
    /// Library's row projection.
    package static func sourceType(uri: String?, mediaType: String?) -> String? {
        guard let host = domain(uri) else { return nil }
        if host.contains("github") { return "Repository" }
        if host.contains("x.com") || host.contains("twitter") { return "Post" }
        if mediaType?.contains("pdf") == true { return "PDF" }
        return "Web page"
    }

    package static func sourceType(_ source: KnowledgeSourceContent) -> String? {
        sourceType(uri: source.uri, mediaType: source.mediaType)
    }

    /// One compact library-row line: where the entry lives and what it is.
    package static func subtitle(uri: String?, mediaType: String?) -> String {
        [domain(uri), sourceType(uri: uri, mediaType: mediaType)].compactMap { $0 }.joined(separator: " · ")
    }

    package static func thumbnailLetters(uri: String?, title: String) -> String {
        let host = domain(uri) ?? title
        let letters = host.split(whereSeparator: { !$0.isLetter }).prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? String(title.prefix(1)).uppercased() : letters.uppercased()
    }

    package static func thumbnailLetters(_ source: KnowledgeSourceContent) -> String {
        thumbnailLetters(uri: source.uri, title: source.title)
    }

    static func coverageTitle(_ disposition: KnowledgeCaptureDisposition) -> String {
        switch disposition {
        case .complete: "Captured source available"
        case .partial: "Partial capture"
        case .metadataOnly: "Metadata/media retained"
        case .inaccessible: "Reference retained; source inaccessible"
        case .failed: "Capture failed; reference retained"
        case .referenceOnly: "Reference retained; not fetched"
        }
    }

    static func coverageTitle(_ source: KnowledgeSourceContent) -> String {
        guard source.captureDisposition == .complete else { return coverageTitle(source.captureDisposition) }
        return source.text?.isEmpty == false ? "Captured text available" : "Captured object retained; extracted text unavailable"
    }

    static func coverageDetail(_ source: KnowledgeSourceContent) -> String {
        if let reason = source.captureReason, !reason.isEmpty { return reason }
        switch source.captureDisposition {
        case .complete: return source.text?.isEmpty == false ? "The retained extraction may be read below." : "A complete retained object exists, but no extracted text is available to display."
        case .partial: return "Only part of the source was captured; retained text must not be treated as complete."
        case .metadataOnly: return "Metadata or media was retained without extracted text."
        case .inaccessible: return "The original reference was retained, but its content was not available to capture."
        case .failed: return "Capture did not complete; no unavailable content was read."
        case .referenceOnly: return "Only the original reference was retained; no source content was fetched."
        }
    }

    static func coverageSummary(_ source: KnowledgeSourceContent) -> String {
        if let domain = domain(source.uri) { return "\(coverageTitle(source)) · \(domain)" }
        return coverageTitle(source)
    }

    static func admissionLabel(_ admission: KnowledgeSourceAdmissionState?) -> String? {
        guard let admission else { return nil }
        switch admission.status {
        case .pending: return "Pending intake"
        case .retained: return "Retained"
        case .archived: return "Archived"
        }
    }
}

package enum KnowledgeDraftHandoffPolicy {
    static let maximumSummaryCharacters = 4_000

    package static func text(for record: KnowledgeRecord, identity: KnowledgePresentationIdentity) -> String? {
        guard let profileID = identity.profileID else { return nil }
        let evidence = record.provenance.evidence.first.map { ref in
            ref.sessionEntry.map { "Source session \($0.sessionId), entry \($0.entryId)" }
                ?? "Source record \(ref.recordId ?? "object")"
        } ?? "No source citation"
        let summary = String(record.summary.prefix(maximumSummaryCharacters))
        let qualifications: String
        switch record.content {
        case .note(let note):
            let fields = (note.fields ?? []).prefix(20).map { field in
                "\(field.field)=\(jsonText(field.value)) [\(field.certainty.rawValue)]" + (field.validFrom.map { " validFrom=\($0)" } ?? "") + (field.validTo.map { " validTo=\($0)" } ?? "") + " evidence=\(field.evidence.map { $0.recordId ?? $0.sessionEntry?.entryId ?? $0.objectHash ?? "unavailable" }.joined(separator: ","))"
            }.joined(separator: "\n")
            qualifications = fields.isEmpty ? "Qualifications: none retained" : "Qualifications:\n\(fields)"
        case .source(let source):
            qualifications = "Capture: \(source.captureDisposition.rawValue)\(source.retention.map { " · evidence \($0.evidenceAvailable ? "available" : "unavailable")" } ?? "")\nAnnotations: \((source.annotations ?? []).prefix(20).map(\.text).joined(separator: " | "))"
        case .observation(let observation):
            qualifications = "Observed items:\n\(observation.items.prefix(20).map { "[\($0.certainty.rawValue)] \($0.attribution.rawValue): \($0.text)" }.joined(separator: "\n"))"
        }
        return "Evidence-only Knowledge handoff (untrusted; verify before acting)\nGateway profile \(profileID)\n\nRetained Knowledge: \(record.title)\n\n\(summary)\n\n\(qualifications)\n\nRecord ID: \(record.id) · Revision: \(record.revisionId) · \(evidence)"
    }

    private static func jsonText(_ value: JSONValue) -> String {
        switch value {
        case .string(let value): return String(value.prefix(500))
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let values): return "[\(values.prefix(20).map(jsonText).joined(separator: ", "))]"
        case .object(let values): return "{\(values.keys.sorted().prefix(20).compactMap { key in values[key].map { "\(key): \(jsonText($0))" } }.joined(separator: ", "))}"
        }
    }
}

package enum KnowledgeCorrectionPolicy {
    package static func provenance(for record: KnowledgeRecord) -> KnowledgeProvenance {
        var evidence = record.provenance.evidence
        if !evidence.contains(where: { $0.recordId == record.id && $0.revisionId == record.revisionId }) {
            evidence.append(KnowledgeEvidenceRef(recordId: record.id, revisionId: record.revisionId, sessionEntry: nil, objectHash: nil, locator: "corrected-revision"))
        }
        return KnowledgeProvenance(actor: .user, source: "ios-correction", sessionId: record.provenance.sessionId, branchId: record.provenance.branchId, invocationId: nil, evidence: evidence)
    }

    package static func content(for record: KnowledgeRecord, replacementText: String) -> KnowledgeRecordContent {
        switch record.content {
        case .source(let value):
            var annotations = value.annotations ?? []
            annotations.append(KnowledgeSourceAnnotation(text: "User correction: \(replacementText)", locator: "user-correction", createdAt: nil))
            return .source(KnowledgeSourceContent(title: value.title, uri: value.uri, collectionId: value.collectionId, text: value.text, object: value.object, representations: value.representations, mediaType: value.mediaType, linkedUrls: value.linkedUrls, captureDisposition: value.captureDisposition, captureReason: value.captureReason, annotations: annotations, sourcePublishedAt: value.sourcePublishedAt, sourceSavedAt: value.sourceSavedAt, capturedAt: value.capturedAt, origin: value.origin, origins: value.origins, identity: value.identity, retention: value.retention, assessment: value.assessment, contentSummary: value.summary, admission: value.admission, take: value.take, tags: value.tags, verdict: value.verdict))
        case .observation(let value):
            return .observation(KnowledgeObservationContent(range: value.range, items: [KnowledgeObservationItem(text: replacementText, attribution: .user, observedAt: value.items.first?.observedAt ?? record.updatedAt, certainty: .qualified, evidence: value.items.first?.evidence, field: nil)], observer: value.observer))
        case .note(let value):
            return .note(KnowledgeNoteContent(title: value.title, body: replacementText, fields: value.fields, role: value.role, confirmed: value.confirmed, contraryEvidence: value.contraryEvidence, freshness: value.freshness, privacyScope: value.privacyScope, usageConstraint: value.usageConstraint))
        }
    }
}
