import Foundation
import Observation
import CryptoKit

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
enum KnowledgeSourceRepresentationKind: String, Codable, Hashable, Sendable { case providerAPI = "provider-api"; case linkedArticle = "linked-article" }
struct KnowledgeSourceRepresentation: Codable, Hashable, Sendable { let kind: KnowledgeSourceRepresentationKind; let object: KnowledgeObjectRef; let mediaType: String? }
struct KnowledgeObjectRead: Codable, Hashable, Sendable { let hash: String; let mediaType: String; let bytes: Int; let totalBytes: Int?; let offset: Int?; let nextOffset: Int?; let base64: String }
enum KnowledgeCoverageDisposition: String, Codable, Hashable, Sendable { case observed, empty, excluded, pending, failed, unavailable }
struct KnowledgeCoverageSummary: Codable, Hashable, Sendable {
    let observedCount: Int; let emptyCount: Int; let excludedCount: Int; let pendingCount: Int; let failedCount: Int; let unavailableCount: Int; let remainingCount: Int
}
struct KnowledgeObservationCoverage: Codable, Hashable, Sendable, Identifiable {
    let schemaVersion: Int; let id: String; let revisionId: String; let range: KnowledgeObservationRange
    let disposition: KnowledgeCoverageDisposition; let groupRevisionIds: [String]; let recordedAt: String; let reason: String?
}
struct KnowledgeCoverageDismissResult: Codable, Sendable {
    let coverage: KnowledgeObservationCoverage
    let stateRevision: Int
}
struct KnowledgeCoveragePage: Codable, Hashable, Sendable {
    let coverage: [KnowledgeObservationCoverage]; let stateRevision: Int; let nextCursor: String?
}

/// Owns the bounded coverage projection and its cursor. Pages are requested by
/// disposition, so the projection holds cuts that need attention rather than the
/// settled majority of the ledger. A continuation appends to that projection
/// across a revision change (deduplicating re-recorded cuts) so paging always
/// advances instead of restarting at the head.
@MainActor @Observable
final class KnowledgeCoveragePresentationStore {
    private(set) var cuts: [KnowledgeObservationCoverage] = []
    private(set) var nextCursor: String?
    private(set) var stateRevision: Int?
    private(set) var loading = false
    private(set) var error: String?
    private var generation = 0
    private var identity: KnowledgePresentationIdentity?
    private var requestedCursor: String?
    var showsInitialLoading: Bool { loading && stateRevision == nil }

    func suspend() { generation &+= 1; loading = false }
    func reset() { generation &+= 1; cuts = []; nextCursor = nil; stateRevision = nil; error = nil; loading = false; identity = nil; requestedCursor = nil }

    func load(
        identity: KnowledgePresentationIdentity,
        cursor: String? = nil,
        expectedStateRevision: Int? = nil,
        request: @Sendable (String?) async throws -> KnowledgeCoveragePage,
        isCurrent: @MainActor () -> Bool
    ) async {
        guard !Task.isCancelled, isCurrent() else { return }
        guard !loading || self.identity != identity || requestedCursor != cursor else { return }
        if self.identity != identity { reset() }
        if cursor == nil, let expectedStateRevision, stateRevision == expectedStateRevision, error == nil { return }
        self.identity = identity; requestedCursor = cursor; generation &+= 1
        let ticket = generation
        // A same-Gateway refresh replaces the page only after it arrives. A
        // covered/uncovered sheet must not flash an empty coverage container.
        loading = true; error = nil
        do {
            let page = try await request(cursor)
            guard !Task.isCancelled, ticket == generation, isCurrent() else { return }
            if cursor == nil {
                cuts = page.coverage
            } else {
                // The coverage ledger is ordered by recordedAt and only ever
                // appends a cut or moves one forward (new and re-recorded cuts
                // are stamped with the current time), so a continuation stays
                // coherent across a revision change. A cut that was re-recorded
                // after this page started replaces its retained copy rather than
                // appearing twice; a page of already-known cuts still advances
                // the cursor instead of restarting at the head.
                let refreshed = Set(page.coverage.map(\.id))
                cuts = cuts.filter { !refreshed.contains($0.id) } + page.coverage
            }
            nextCursor = page.nextCursor; stateRevision = page.stateRevision; loading = false
        } catch is CancellationError {
            if ticket == generation { loading = false }
        }
        catch {
            guard !Task.isCancelled, ticket == generation, isCurrent() else { return }
            self.error = error.localizedDescription; loading = false
        }
    }

    func loadMore(
        identity: KnowledgePresentationIdentity,
        request: @Sendable (String?) async throws -> KnowledgeCoveragePage,
        isCurrent: @MainActor () -> Bool
    ) async {
        guard let cursor = nextCursor else { return }
        await load(identity: identity, cursor: cursor, request: request, isCurrent: isCurrent)
    }
}

struct KnowledgeObjectSelectionKey: Hashable, Sendable {
    let recordID: String; let revisionID: String; let reference: KnowledgeObjectRef
}
struct KnowledgeObjectReaderState: Sendable {
    var bytes = Data(); var totalBytes: Int?; var nextOffset: Int?; var loading = false; var error: String?; var generation = 0
}

enum KnowledgeObjectPresentationPolicy {
    static func renderedText(_ bytes: Data, mediaType: String, label: String) -> String {
        let type = mediaType.lowercased()
        if type.hasPrefix("text/") || type == "application/json" || type == "application/xml" {
            if let text = String(data: bytes, encoding: .utf8) { return text }
            return String(decoding: bytes, as: UTF8.self)
        }
        return "Binary \(label) (\(bytes.count) bytes loaded)"
    }
}

/// Owns linked-record reads for the active detail. A late response cannot
/// navigate after a newer citation, dismissal, or Gateway profile change.
@MainActor @Observable
final class KnowledgeLinkedRecordReaderStore {
    private(set) var record: KnowledgeRecord?
    private(set) var loading = false
    private(set) var error: String?
    private var generation = 0

    func suspend() { generation &+= 1; loading = false }
    func clear() { record = nil }
    func load(id: String, revisionID: String?, request: @Sendable (String, String?) async throws -> KnowledgeRecord?, isCurrent: @MainActor () -> Bool) async {
        guard !Task.isCancelled, isCurrent() else { return }
        generation &+= 1; let ticket = generation; let ownerGeneration = generation
        record = nil; error = nil; loading = true
        do {
            let value = try await request(id, revisionID)
            guard !Task.isCancelled, ticket == generation, generation == ownerGeneration, isCurrent() else { return }
            loading = false
            if let value { record = value } else { error = "Linked record is unavailable, excluded, or forgotten. Retry from this detail." }
        } catch is CancellationError {
            if ticket == generation, generation == ownerGeneration { loading = false }
        }
        catch {
            guard !Task.isCancelled, ticket == generation, generation == ownerGeneration, isCurrent() else { return }
            loading = false; self.error = error.localizedDescription
        }
    }
}

/// One bounded reader state for the currently selected exact record revision
/// and representation. Continuation offsets are never shared across objects,
/// and changing selection releases the prior representation.
@MainActor @Observable
final class KnowledgeObjectReaderStore {
    // A detail can switch representations, but it only owns one bounded byte
    // buffer at a time. Keeping old revisions here would turn a presentation
    // projection into an unbounded corpus cache.
    private(set) var states: [KnowledgeObjectSelectionKey: KnowledgeObjectReaderState] = [:]
    private var activeKey: KnowledgeObjectSelectionKey?
    private var generation = 0

    func state(for key: KnowledgeObjectSelectionKey) -> KnowledgeObjectReaderState { activeKey == key ? (states[key] ?? KnowledgeObjectReaderState()) : KnowledgeObjectReaderState() }
    func suspend() {
        generation &+= 1
        guard let activeKey, var state = states[activeKey] else { return }
        state.loading = false
        states[activeKey] = state
    }

    func load(
        _ key: KnowledgeObjectSelectionKey,
        offset: Int,
        request: @Sendable (KnowledgeObjectRef, Int) async throws -> KnowledgeObjectRead?,
        isCurrent: @MainActor () -> Bool
    ) async {
        guard !Task.isCancelled, isCurrent() else { return }
        if activeKey != key {
            states.removeAll(keepingCapacity: true)
            activeKey = key
        }
        var current = states[key] ?? KnowledgeObjectReaderState()
        current.generation &+= 1; let ticket = current.generation; let ownerGeneration = generation
        current.loading = true; current.error = nil; states[key] = current
        let requestedOffset = max(0, offset)
        do {
            let value = try await request(key.reference, requestedOffset)
            guard !Task.isCancelled, generation == ownerGeneration, isCurrent(), activeKey == key, states[key]?.generation == ticket else { return }
            guard let value, let bytes = Data(base64Encoded: value.base64),
                  value.hash == key.reference.hash,
                  value.mediaType == key.reference.mediaType,
                  value.bytes >= 0, value.bytes <= 512_000,
                  value.totalBytes == key.reference.bytes, value.totalBytes! >= 0, value.totalBytes! <= 512_000,
                  value.offset == requestedOffset,
                  bytes.count == value.bytes,
                  value.offset! <= value.totalBytes! - value.bytes,
                  (value.nextOffset == nil
                    ? value.offset! + value.bytes == value.totalBytes!
                    : value.nextOffset == value.offset! + value.bytes && value.nextOffset! > value.offset! && value.nextOffset! <= value.totalBytes!) else {
                states[key]?.loading = false
                states[key]?.error = "Retained object response is invalid."
                return
            }
            var updated = states[key] ?? KnowledgeObjectReaderState()
            guard requestedOffset == 0 || requestedOffset == updated.bytes.count else {
                updated.loading = false; updated.error = "The retained object changed while it was being read; reopen this representation."; states[key] = updated; return
            }
            if requestedOffset == 0 { updated.bytes = bytes } else { updated.bytes.append(bytes) }
            updated.totalBytes = value.totalBytes; updated.nextOffset = value.nextOffset; updated.loading = false; states[key] = updated
        } catch is CancellationError {
            // Cancellation must not leave the button disabled when the detail
            // becomes active again. A newer request still owns its own ticket.
            if generation == ownerGeneration, activeKey == key, states[key]?.generation == ticket { states[key]?.loading = false }
        }
        catch {
            guard !Task.isCancelled, generation == ownerGeneration, isCurrent(), activeKey == key, states[key]?.generation == ticket else { return }
            states[key]?.loading = false; states[key]?.error = error.localizedDescription
        }
    }
}
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
enum KnowledgeEvidenceQuality: String, Codable, Sendable { case high, medium, low, none, unknown }
enum KnowledgeFreshness: String, Codable, Sendable { case current, aging, stale, unknown }
enum KnowledgeSourceAdmission: String, Codable, Hashable, Sendable { case pending, retained, archived }
struct KnowledgeSourceSummaryTag: Codable, Hashable, Sendable { let label: String; let kind: String }
struct KnowledgeSourceSummary: Codable, Hashable, Sendable {
    let text: String; let tags: [KnowledgeSourceSummaryTag]; let generatedAt: String; let sourceRevisionId: String; let evidenceDigest: String; let coverage: String
}
struct KnowledgeSourceAssessmentUsage: Codable, Hashable, Sendable {
    // Assessment pricing may be a fraction of one cent; match the Gateway number contract.
    let inputTokens: Int; let outputTokens: Int; let estimatedCostCents: Double; let pricing: String
}
struct KnowledgeSourceAssessment: Codable, Hashable, Sendable {
    let summary: String; let contribution: String?; let whyItMatters: String?; let evidenceQuality: KnowledgeEvidenceQuality; let freshness: KnowledgeFreshness; let possibleUse: String?; let generatedAt: String; let model: String?; let recommendation: KnowledgeSourceAdmission?; let confidence: Double?; let profileVersion: String?; let rubricVersion: String?
    // These fields are provider assessment metadata, not capture completeness or epistemic confidence.
    let inputDigest: String?; let evidenceDigest: String?; let assessmentInputDigest: String?; let coverage: String?; let classification: String?; let usage: KnowledgeSourceAssessmentUsage?
    init(summary: String, contribution: String?, whyItMatters: String?, evidenceQuality: KnowledgeEvidenceQuality, freshness: KnowledgeFreshness, possibleUse: String?, generatedAt: String, model: String?, recommendation: KnowledgeSourceAdmission? = nil, confidence: Double? = nil, profileVersion: String? = nil, rubricVersion: String? = nil, inputDigest: String? = nil, evidenceDigest: String? = nil, assessmentInputDigest: String? = nil, coverage: String? = nil, classification: String? = nil, usage: KnowledgeSourceAssessmentUsage? = nil) {
        self.summary = summary; self.contribution = contribution; self.whyItMatters = whyItMatters; self.evidenceQuality = evidenceQuality; self.freshness = freshness; self.possibleUse = possibleUse; self.generatedAt = generatedAt; self.model = model; self.recommendation = recommendation; self.confidence = confidence; self.profileVersion = profileVersion; self.rubricVersion = rubricVersion; self.inputDigest = inputDigest; self.evidenceDigest = evidenceDigest; self.assessmentInputDigest = assessmentInputDigest; self.coverage = coverage; self.classification = classification; self.usage = usage
    }
    private enum CodingKeys: String, CodingKey { case summary, contribution, whyItMatters, evidenceQuality, freshness, possibleUse, generatedAt, model, recommendation, confidence, profileVersion, rubricVersion, inputDigest, evidenceDigest, assessmentInputDigest, coverage, classification, usage }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(String.self, forKey: .summary); contribution = try c.decodeIfPresent(String.self, forKey: .contribution); whyItMatters = try c.decodeIfPresent(String.self, forKey: .whyItMatters)
        evidenceQuality = try c.decode(KnowledgeEvidenceQuality.self, forKey: .evidenceQuality); freshness = try c.decode(KnowledgeFreshness.self, forKey: .freshness); possibleUse = try c.decodeIfPresent(String.self, forKey: .possibleUse); generatedAt = try c.decode(String.self, forKey: .generatedAt); model = try c.decodeIfPresent(String.self, forKey: .model)
        recommendation = try c.decodeIfPresent(KnowledgeSourceAdmission.self, forKey: .recommendation); confidence = try c.decodeIfPresent(Double.self, forKey: .confidence); profileVersion = try c.decodeIfPresent(String.self, forKey: .profileVersion); rubricVersion = try c.decodeIfPresent(String.self, forKey: .rubricVersion)
        inputDigest = try c.decodeIfPresent(String.self, forKey: .inputDigest); evidenceDigest = try c.decodeIfPresent(String.self, forKey: .evidenceDigest); assessmentInputDigest = try c.decodeIfPresent(String.self, forKey: .assessmentInputDigest); coverage = try c.decodeIfPresent(String.self, forKey: .coverage); classification = try c.decodeIfPresent(String.self, forKey: .classification); usage = try c.decodeIfPresent(KnowledgeSourceAssessmentUsage.self, forKey: .usage)
    }
}
struct KnowledgeSourceAdmissionState: Codable, Hashable, Sendable { let status: KnowledgeSourceAdmission; let reason: String?; let decidedAt: String; let profileVersion: String?; let rubricVersion: String? }
struct KnowledgeSourceRetention: Codable, Hashable, Sendable { let sensitivity: String; let usageConstraint: String?; let evidenceAvailable: Bool; let originalHash: String? }
struct KnowledgeSourceContent: Codable, Hashable, Sendable {
    let title: String; let uri: String?; var collectionId: String?; let text: String?; let object: KnowledgeObjectRef?; let preview: KnowledgeObjectRef?; var representations: [KnowledgeSourceRepresentation]?; let mediaType: String?; let linkedUrls: [String]?
    let captureDisposition: KnowledgeCaptureDisposition; let captureReason: String?; let annotations: [KnowledgeSourceAnnotation]?; let sourcePublishedAt: String?; let sourceSavedAt: String?; let capturedAt: String; let origin: String?
    let origins: [KnowledgeSourceOrigin]?; let identity: KnowledgeSourceIdentity?; var retention: KnowledgeSourceRetention?; let assessment: KnowledgeSourceAssessment?; let summary: KnowledgeSourceSummary?; var admission: KnowledgeSourceAdmissionState?
    init(title: String, uri: String?, collectionId: String? = nil, text: String?, object: KnowledgeObjectRef?, preview: KnowledgeObjectRef? = nil, representations: [KnowledgeSourceRepresentation]? = nil, mediaType: String?, linkedUrls: [String]? = nil, captureDisposition: KnowledgeCaptureDisposition, captureReason: String? = nil, annotations: [KnowledgeSourceAnnotation]?, sourcePublishedAt: String?, sourceSavedAt: String? = nil, capturedAt: String, origin: String?, origins: [KnowledgeSourceOrigin]?, identity: KnowledgeSourceIdentity?, retention: KnowledgeSourceRetention? = nil, assessment: KnowledgeSourceAssessment?, contentSummary: KnowledgeSourceSummary? = nil, admission: KnowledgeSourceAdmissionState? = nil) {
        self.title = title; self.uri = uri; self.collectionId = collectionId; self.text = text; self.object = object; self.preview = preview; self.representations = representations; self.mediaType = mediaType; self.linkedUrls = linkedUrls; self.captureDisposition = captureDisposition; self.captureReason = captureReason; self.annotations = annotations; self.sourcePublishedAt = sourcePublishedAt; self.sourceSavedAt = sourceSavedAt; self.capturedAt = capturedAt; self.origin = origin; self.origins = origins; self.identity = identity; self.retention = retention; self.assessment = assessment; self.summary = contentSummary; self.admission = admission
    }
    private enum CodingKeys: String, CodingKey { case title, uri, collectionId, text, object, preview, representations, mediaType, linkedUrls, captureDisposition, captureReason, annotations, sourcePublishedAt, sourceSavedAt, capturedAt, origin, origins, identity, retention, assessment, summary, admission }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title); uri = try c.decodeIfPresent(String.self, forKey: .uri); collectionId = try c.decodeIfPresent(String.self, forKey: .collectionId); text = try c.decodeIfPresent(String.self, forKey: .text); object = try c.decodeIfPresent(KnowledgeObjectRef.self, forKey: .object); preview = try c.decodeIfPresent(KnowledgeObjectRef.self, forKey: .preview); representations = try c.decodeIfPresent([KnowledgeSourceRepresentation].self, forKey: .representations); mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType); linkedUrls = try c.decodeIfPresent([String].self, forKey: .linkedUrls)
        captureDisposition = try c.decode(KnowledgeCaptureDisposition.self, forKey: .captureDisposition); captureReason = try c.decodeIfPresent(String.self, forKey: .captureReason); annotations = try c.decodeIfPresent([KnowledgeSourceAnnotation].self, forKey: .annotations); sourcePublishedAt = try c.decodeIfPresent(String.self, forKey: .sourcePublishedAt); sourceSavedAt = try c.decodeIfPresent(String.self, forKey: .sourceSavedAt); capturedAt = try c.decode(String.self, forKey: .capturedAt); origin = try c.decodeIfPresent(String.self, forKey: .origin)
        origins = try c.decodeIfPresent([KnowledgeSourceOrigin].self, forKey: .origins); identity = try c.decodeIfPresent(KnowledgeSourceIdentity.self, forKey: .identity); retention = try c.decodeIfPresent(KnowledgeSourceRetention.self, forKey: .retention); assessment = try c.decodeIfPresent(KnowledgeSourceAssessment.self, forKey: .assessment); summary = try c.decodeIfPresent(KnowledgeSourceSummary.self, forKey: .summary); admission = try c.decodeIfPresent(KnowledgeSourceAdmissionState.self, forKey: .admission)
    }
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
extension KnowledgeRecordContent {
    var sourcePreviewHash: String? { if case .source(let source) = self { return source.preview?.hash }; return nil }
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

struct KnowledgeEligibility: Codable, Hashable, Sendable {
    // Only an explicit true grants global scope. Omission retains the selected
    // sessions/projects, including the intentionally empty initial selection.
    var allSessions: Bool?
    var sessionIds: [String]; var projectIds: [String]; var excludedSessionIds: [String]; var excludedProjectIds: [String]
}
struct KnowledgeObservationLimits: Codable, Hashable, Sendable { var enabled: Bool; var model: String?; var maxInputChars: Int; var maxOutputChars: Int; var timeoutMs: Int; var maxAttempts: Int }

enum KnowledgeObservationConfigurationPolicy {
    static func admitsEnable(hasModel: Bool, supportsGlobalObservation: Bool) -> Bool {
        hasModel && supportsGlobalObservation
    }

    static func applyingGlobalGrant(_ config: KnowledgeConfig, enabled: Bool) -> KnowledgeConfig {
        var next = config
        next.observation.enabled = enabled
        if enabled { next.eligibility.allSessions = true }
        return next
    }
}

struct KnowledgeConfig: Codable, Hashable, Sendable {
    let schemaVersion: Int; var revision: Int; var eligibility: KnowledgeEligibility; var observation: KnowledgeObservationLimits; var maximumSearchResults: Int; var currentInterests: [String]
}
struct KnowledgeStatus: Codable, Hashable, Sendable {
    let available: Bool; let state: String; let stateRevision: Int?; let recordCount: Int; let coverageCount: Int; let coverage: KnowledgeCoverageSummary; let suppressedCount: Int; let pendingCleanupCount: Int; let config: KnowledgeConfig; let observationConfigured: Bool; let detail: String?
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
    let connector: String; let connectionId: String?; let configured: Bool; let enabled: Bool; let health: String; let credentialAvailability: String?; let providerIdentity: String?; let accountId: String?; let scope: String?; let destination: String?; let lastRunAt: String?; let lastError: String?; let remaining: Int; let pending: Int; let paidBudgetCents: Int; let allowWrites: Bool; let recurringApproved: Bool; let paidAccessApproved: Bool
    /// Configuration is intent; provider use is available only after both
    /// bounded owner observations admit the credential and account identity.
    var available: Bool { health == "ready" && credentialAvailability == "available" && providerIdentity == "admitted" }
    var writesEnabled: Bool { allowWrites }
    var state: String { health }
    var detail: String? { lastError ?? (available ? nil : "Provider admission is not established.") }
}
struct KnowledgeConnectorRunResult: Codable, Hashable, Sendable { let dryRun: Bool; let connector: String; let discovered: Int; let captured: Int?; let pending: Int; let remaining: Int?; let health: String; let partial: Int?; let error: String? }
struct KnowledgeTriageResult: Codable, Hashable, Sendable { let source: KnowledgeRecord; let assessment: KnowledgeSourceAssessment }

struct KnowledgeListRequest: Encodable, Sendable {
    let kind: KnowledgeRecordKind?; let scope: KnowledgeScope?; let includeSuppressed: Bool; let includeArchived: Bool?; let includePending: Bool?; let sourceAdmission: KnowledgeSourceAdmission?; let cursor: String?; let limit: Int
}
struct KnowledgeSearchRequest: Encodable, Sendable {
    let query: String; let kind: KnowledgeRecordKind?; let scope: KnowledgeScope?; let includeArchived: Bool?; let includePending: Bool?; let sourceAdmission: KnowledgeSourceAdmission?; let limit: Int
}
struct KnowledgeRecallRequest: Encodable, Sendable { let query: String?; let sessionId: String?; let entryId: String?; let scope: KnowledgeScope?; let limit: Int }

extension KnowledgeRecord {
    var title: String {
        switch content { case .source(let c): c.title; case .observation: "Observation"; case .note(let c): c.title }
    }
    var summary: String {
        switch content { case .source(let c): KnowledgeSourcePresentationPolicy.summary(c) ?? ""; case .observation(let c): c.items.map { $0.text }.joined(separator: " "); case .note(let c): c.body ?? "" }
    }
}

/// Presentation-only source semantics. Capture coverage, intake admission, and
/// assessment quality remain separate so a partial/reference source is never
/// presented as complete text or as a confidence score.
enum KnowledgeSourcePresentationPolicy {
    static func safeURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func domain(_ value: String?) -> String? { safeURL(value)?.host?.lowercased() }

    /// Connector captures retain the requested URL alongside the resolved page URL.
    /// Prefer the latest origin for this exact saved item; unrelated referral origins
    /// must never redirect the source's Open original action.
    static func originalURL(_ source: KnowledgeSourceContent) -> URL? {
        if let identity = source.identity,
           let requested = source.origins?.reversed().first(where: { origin in
               origin.identity == identity && origin.uri != nil && origin.uri != source.uri
           })?.uri {
            return safeURL(requested)
        }
        return safeURL(source.uri)
    }

    static func publishedAt(_ source: KnowledgeSourceContent) -> String? {
        // Earlier Raindrop intake incorrectly stored its `created` (bookmark-save)
        // timestamp as publication time. Do not repeat that claim on old records.
        guard source.identity?.provider.lowercased() != "raindrop" else { return nil }
        return source.sourcePublishedAt
    }

    static func summary(_ source: KnowledgeSourceContent) -> String? {
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

    static func sourceType(_ source: KnowledgeSourceContent) -> String? {
        guard let host = domain(source.uri) else { return nil }
        if host.contains("github") { return "Repository" }
        if host.contains("x.com") || host.contains("twitter") { return "Post" }
        if source.mediaType?.contains("pdf") == true { return "PDF" }
        return "Web page"
    }

    static func decodeSavedTextEntities(_ value: String) -> String {
        // Ampersands last: &amp;#x27; denotes the literal entity, not an apostrophe.
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func thumbnailLetters(_ source: KnowledgeSourceContent) -> String {
        let host = domain(source.uri) ?? source.title
        let letters = host.split(whereSeparator: { !$0.isLetter }).prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? String(source.title.prefix(1)).uppercased() : letters.uppercased()
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

enum KnowledgeDraftHandoffPolicy {
    static let maximumSummaryCharacters = 4_000

    static func text(for record: KnowledgeRecord, identity: KnowledgePresentationIdentity) -> String? {
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

enum KnowledgeCorrectionPolicy {
    static func provenance(for record: KnowledgeRecord) -> KnowledgeProvenance {
        var evidence = record.provenance.evidence
        if !evidence.contains(where: { $0.recordId == record.id && $0.revisionId == record.revisionId }) {
            evidence.append(KnowledgeEvidenceRef(recordId: record.id, revisionId: record.revisionId, sessionEntry: nil, objectHash: nil, locator: "corrected-revision"))
        }
        return KnowledgeProvenance(actor: .user, source: "ios-correction", sessionId: record.provenance.sessionId, branchId: record.provenance.branchId, invocationId: nil, evidence: evidence)
    }

    static func content(for record: KnowledgeRecord, replacementText: String) -> KnowledgeRecordContent {
        switch record.content {
        case .source(let value):
            var annotations = value.annotations ?? []
            annotations.append(KnowledgeSourceAnnotation(text: "User correction: \(replacementText)", locator: "user-correction", createdAt: nil))
            return .source(KnowledgeSourceContent(title: value.title, uri: value.uri, collectionId: value.collectionId, text: value.text, object: value.object, representations: value.representations, mediaType: value.mediaType, linkedUrls: value.linkedUrls, captureDisposition: value.captureDisposition, captureReason: value.captureReason, annotations: annotations, sourcePublishedAt: value.sourcePublishedAt, sourceSavedAt: value.sourceSavedAt, capturedAt: value.capturedAt, origin: value.origin, origins: value.origins, identity: value.identity, retention: value.retention, assessment: value.assessment, contentSummary: value.summary, admission: value.admission))
        case .observation(let value):
            return .observation(KnowledgeObservationContent(range: value.range, items: [KnowledgeObservationItem(text: replacementText, attribution: .user, observedAt: value.items.first?.observedAt ?? record.updatedAt, certainty: .qualified, evidence: value.items.first?.evidence, field: nil)], observer: value.observer))
        case .note(let value):
            return .note(KnowledgeNoteContent(title: value.title, body: replacementText, fields: value.fields, role: value.role, confirmed: value.confirmed, contraryEvidence: value.contraryEvidence, freshness: value.freshness, privacyScope: value.privacyScope, usageConstraint: value.usageConstraint))
        }
    }
}
