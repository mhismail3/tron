import Foundation
@testable import TronMobile

enum KnowledgeObservationFixture {
    static func record() -> KnowledgeRecord {
        let range = KnowledgeObservationRange(sessionId: "fixture-session", branchId: "fixture-branch",
            fromEntryId: "fixture-first", toEntryId: "fixture-last", entryIds: ["fixture-first", "fixture-last"],
            entryDigest: String(repeating: "a", count: 64), projectId: "fixture-project", invocationIds: ["fixture-invocation"])
        let citations = range.entryIds.map {
            KnowledgeEvidenceRef(recordId: nil, revisionId: nil,
                sessionEntry: KnowledgeSessionEntryCitation(sessionId: range.sessionId, branchId: range.branchId,
                    entryId: $0, digest: range.entryDigest, startOffset: nil, endOffset: nil), objectHash: nil, locator: nil)
        }
        return KnowledgeRecord(schemaVersion: 1, id: "fixture-observation", revisionId: "fixture-revision",
            kind: .observation, scope: .personal, createdAt: "2026-01-02T12:00:00Z", updatedAt: "2026-03-04T12:00:00Z",
            provenance: KnowledgeProvenance(actor: .agent, source: nil, sessionId: range.sessionId,
                branchId: range.branchId, invocationId: "fixture-invocation", evidence: citations),
            temporal: nil, relations: [], content: .observation(KnowledgeObservationContent(range: range,
                items: [.init(text: "The user prefers concise explanations.", attribution: .user,
                    observedAt: "2026-01-01T09:30:00Z", certainty: .qualified, evidence: nil, field: nil)],
                observer: .init(model: "fixture/model", promptVersion: "tron-observer-v2"))))
    }
}
