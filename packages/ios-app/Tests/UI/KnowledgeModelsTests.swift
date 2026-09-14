import XCTest
@testable import TronMobile

final class KnowledgeModelsTests: XCTestCase {
    func testObservationRoundTripPreservesCanonicalInputIdentity() throws {
        let range = KnowledgeObservationRange(
            sessionId: "session-1", branchId: "branch-1", fromEntryId: "entry-1", toEntryId: "entry-2",
            entryIds: ["entry-1", "entry-2"], entryDigest: String(repeating: "a", count: 64), projectId: "project-1", invocationIds: ["invoke-1"]
        )
        let record = KnowledgeRecord(
            schemaVersion: 1, id: "observation-1", revisionId: "revision-1", kind: .observation, scope: .personal,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            provenance: KnowledgeProvenance(actor: .agent, source: nil, sessionId: "session-1", branchId: "branch-1", invocationId: nil, evidence: []),
            temporal: nil, relations: [], content: .observation(KnowledgeObservationContent(
                range: range,
                items: [KnowledgeObservationItem(text: "A correction was made", attribution: .user, observedAt: "2026-01-01T00:00:00Z", certainty: .certain, evidence: nil, field: nil)],
                observer: KnowledgeObserver(model: "provider/model", promptVersion: "observer-v1")
            ))
        )
        let decoded = try JSONDecoder().decode(KnowledgeRecord.self, from: JSONEncoder().encode(record))
        guard case .observation(let content) = decoded.content else { return XCTFail("Expected observation content") }
        XCTAssertEqual(content.range.entryIds, ["entry-1", "entry-2"])
        XCTAssertEqual(content.range.entryDigest, String(repeating: "a", count: 64))
        XCTAssertEqual(decoded.provenance.sessionId, "session-1")
    }

    func testSourceAndNoteUseTheCommonDiscriminatedContentShape() throws {
        let source = KnowledgeRecord(
            schemaVersion: 1, id: "source-1", revisionId: "revision-1", kind: .source, scope: .research,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            provenance: KnowledgeProvenance(actor: .user, source: nil, sessionId: nil, branchId: nil, invocationId: nil, evidence: []), temporal: nil, relations: [],
            content: .source(KnowledgeSourceContent(title: "A link", uri: "https://example.com", text: nil, object: nil, mediaType: nil, captureDisposition: .referenceOnly, annotations: nil, sourcePublishedAt: nil, capturedAt: "2026-01-01T00:00:00Z", origin: "manual", origins: [KnowledgeSourceOrigin(kind: .manual, capturedAt: "2026-01-01T00:00:00Z", annotation: "saved", uri: "https://example.com", identity: nil)], identity: KnowledgeSourceIdentity(provider: "raindrop", accountId: "account", itemId: "item"), assessment: KnowledgeSourceAssessment(summary: "A useful source", contribution: nil, whyItMatters: nil, evidenceQuality: .high, freshness: .current, possibleUse: "cite it", generatedAt: "2026-01-01T00:00:00Z", model: "model")))
        )
        let note = KnowledgeRecord(
            schemaVersion: 1, id: "note-1", revisionId: "revision-1", kind: .note, scope: .personal,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            provenance: KnowledgeProvenance(actor: .user, source: nil, sessionId: nil, branchId: nil, invocationId: nil, evidence: []), temporal: nil, relations: [],
            content: .note(KnowledgeNoteContent(title: "Preference", body: "Keep it concise", fields: nil, role: .preference, confirmed: true, contraryEvidence: nil, freshness: .current, privacyScope: "private", usageConstraint: "Keep private"))
        )
        let data = try JSONEncoder().encode([source, note])
        let decoded = try JSONDecoder().decode([KnowledgeRecord].self, from: data)
        XCTAssertEqual(decoded.map(\.kind), [.source, .note])
        XCTAssertEqual(decoded.map(\.title), ["A link", "Preference"])
        guard case .note(let noteContent) = decoded[1].content else { return XCTFail("Expected note content") }
        XCTAssertEqual(noteContent.usageConstraint, "Keep private")
        guard case .source(let sourceContent) = decoded[0].content else { return XCTFail("Expected source content") }
        XCTAssertEqual(sourceContent.identity?.itemId, "item")
        XCTAssertEqual(sourceContent.assessment?.evidenceQuality, .high)
        XCTAssertEqual(sourceContent.origins?.first?.annotation, "saved")
    }
}
