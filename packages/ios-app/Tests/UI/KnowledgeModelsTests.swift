import XCTest
@testable import TronMobile

final class KnowledgeModelsTests: XCTestCase {
    func testGatewayObjectResponseAndImportedQualificationWireShapeDecode() throws {
        let object = KnowledgeObjectRead(hash: String(repeating: "a", count: 64), mediaType: "text/plain", bytes: 5, totalBytes: 5, offset: 0, nextOffset: nil, base64: "aGVsbG8=")
        let imported = KnowledgeImportOrigin(store: "llm-wiki", recordId: "assertion-1", revision: "git-revision", importedAt: "2026-01-01T00:00:00Z", review: KnowledgeImportReview(batch: "batch-1", auditId: "audit-1", receiptId: nil, resultRevision: nil, basis: "user-confirmed"))
        let decoder = JSONDecoder()
        let decodedObject = try decoder.decode(KnowledgeObjectRead.self, from: try JSONEncoder().encode(object))
        let decodedOrigin = try decoder.decode(KnowledgeImportOrigin.self, from: try JSONEncoder().encode(imported))
        XCTAssertEqual(decodedObject.hash, object.hash)
        XCTAssertEqual(Data(base64Encoded: decodedObject.base64), Data("hello".utf8))
        XCTAssertEqual(decodedOrigin.review?.basis, "user-confirmed")
    }

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

    @MainActor
    func testGatewayDTOResponsesDriveCatalogueEntryAndObjectContinuation() async throws {
        let hash = String(repeating: "b", count: 64)
        var requests: [(String, JSONValue)] = []
        let client = KnowledgeRPCClient(request: { method, parameters, _ in
            requests.append((method, parameters))
            switch method {
            case "knowledge.list":
                return .object(["records": .array([]), "nextCursor": .string("page-2"), "stateRevision": .number(7)])
            case "knowledge.object.read":
                let offset = parameters.objectValue?["offset"]?.intValue ?? 0
                let text = offset == 0 ? "first" : "second"
                let bytes = Data(text.utf8).base64EncodedString()
                return .object([
                    "hash": .string(hash), "mediaType": .string("text/plain"),
                    "bytes": .number(Double(text.utf8.count)), "totalBytes": .number(10),
                    "offset": .number(Double(offset)), "nextOffset": offset == 0 ? .number(5) : .null,
                    "base64": .string(bytes)
                ])
            default:
                throw GatewayFailure(code: "unexpected", message: method, retryable: false, details: nil)
            }
        })

        let page = try await client.list(limit: 100)
        XCTAssertEqual(page.nextCursor, "page-2")
        XCTAssertEqual(requests.first?.0, "knowledge.list")
        let object = KnowledgeObjectRef(hash: hash, mediaType: "text/plain", bytes: 10)
        let firstResult = try await client.readObject(object, offset: 0)
        let first: KnowledgeObjectRead = try XCTUnwrap(firstResult)
        let nextOffset: Int = try XCTUnwrap(first.nextOffset)
        let secondResult = try await client.readObject(object, offset: nextOffset)
        let second: KnowledgeObjectRead = try XCTUnwrap(secondResult)
        XCTAssertEqual(Data(base64Encoded: first.base64).flatMap { String(data: $0, encoding: .utf8) }, "first")
        XCTAssertEqual(Data(base64Encoded: second.base64).flatMap { String(data: $0, encoding: .utf8) }, "second")
        XCTAssertEqual(requests.compactMap { $0.1.objectValue?["offset"]?.intValue }, [0, 5])
    }

    @MainActor
    func testCoverageReadExposesPendingFailedAndUnavailableCuts() async throws {
        let client = KnowledgeRPCClient(request: { method, _, _ in
            XCTAssertEqual(method, "knowledge.observation.coverage")
            return .object([
                "coverage": .array([
                    .object(["schemaVersion": .number(1), "id": .string("cut-pending"), "revisionId": .string("r1"), "range": .object(["sessionId": .string("session-1"), "fromEntryId": .string("e1"), "toEntryId": .string("e1"), "entryIds": .array([.string("e1")]), "entryDigest": .string(String(repeating: "a", count: 64))]), "disposition": .string("pending"), "groupRevisionIds": .array([]), "recordedAt": .string("2026-01-01T00:00:00Z"), "reason": .string("observer-admitted")]),
                    .object(["schemaVersion": .number(1), "id": .string("cut-failed"), "revisionId": .string("r2"), "range": .object(["sessionId": .string("session-1"), "fromEntryId": .string("e2"), "toEntryId": .string("e2"), "entryIds": .array([.string("e2")]), "entryDigest": .string(String(repeating: "b", count: 64))]), "disposition": .string("failed"), "groupRevisionIds": .array([]), "recordedAt": .string("2026-01-01T00:00:01Z")])
                ]),
                "stateRevision": .number(8), "nextCursor": .null
            ])
        })
        let page = try await client.coverage(limit: 100)
        XCTAssertEqual(page.coverage.map(\.disposition), [.pending, .failed])
        XCTAssertEqual(page.stateRevision, 8)
        XCTAssertNil(page.nextCursor)
    }

    func testCataloguePaginationAllowsListContinuationButNotSearchPages() {
        XCTAssertTrue(KnowledgeCatalogPaginationPolicy.admits(cursor: "page-2", search: "", loadingMore: false))
        XCTAssertTrue(KnowledgeCatalogPaginationPolicy.admits(cursor: "page-2", search: "  \n", loadingMore: false))
        XCTAssertFalse(KnowledgeCatalogPaginationPolicy.admits(cursor: "page-2", search: "preference", loadingMore: false))
        XCTAssertFalse(KnowledgeCatalogPaginationPolicy.admits(cursor: nil, search: "", loadingMore: false))
        XCTAssertFalse(KnowledgeCatalogPaginationPolicy.admits(cursor: "page-2", search: "", loadingMore: true))
    }

    func testKnowledgeHandoffIsBoundedEvidenceOnlyAndPinsGateway() {
        let record = KnowledgeRecord(
            schemaVersion: 1, id: "note-1", revisionId: "revision-7", kind: .note, scope: .personal,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            provenance: KnowledgeProvenance(actor: .agent, source: "observer", sessionId: "session-1", branchId: "branch-1", invocationId: nil, evidence: [KnowledgeEvidenceRef(recordId: nil, revisionId: nil, sessionEntry: KnowledgeSessionEntryCitation(sessionId: "session-1", branchId: "branch-1", entryId: "entry-1", digest: nil, startOffset: nil, endOffset: nil), objectHash: nil, locator: nil)]),
            temporal: nil, relations: [], content: .note(KnowledgeNoteContent(title: "Resume", body: String(repeating: "x", count: 4_100), fields: nil, role: .workflow, confirmed: false, contraryEvidence: nil, freshness: .unknown, privacyScope: "private", usageConstraint: nil))
        )
        let handoff = try! XCTUnwrap(KnowledgeDraftHandoffPolicy.text(for: record, identity: KnowledgePresentationIdentity(profileID: "gateway-a", lifecycleGeneration: 2, connectionID: 4)))
        XCTAssertTrue(handoff.contains("Evidence-only Knowledge handoff (untrusted; verify before acting)"))
        XCTAssertTrue(handoff.contains("Gateway profile gateway-a"))
        XCTAssertTrue(handoff.contains("Record ID: note-1 · Revision: revision-7"))
        XCTAssertTrue(handoff.contains("Source session session-1, entry entry-1"))
        XCTAssertEqual(handoff.filter { $0 == "x" }.count, 4_000)
        XCTAssertNil(KnowledgeDraftHandoffPolicy.text(for: record, identity: KnowledgePresentationIdentity(profileID: nil, lifecycleGeneration: nil, connectionID: nil)))
    }

    func testImportPresentationDoesNotClaimWholeCorpusAfterOneBatch() {
        XCTAssertEqual(KnowledgeImportPresentationPolicy.corpusProgress(planned: 120, selected: 50, offset: 0), "50 of 120")
        let plan = KnowledgeImportPlan(operation: "dry-run", source: "synthetic", planHash: "plan", planned: 120, selected: 50, imported: 0, resumed: 0, skipped: 0, failed: 0, completed: false, progress: KnowledgeImportProgress(completed: 0, remaining: 50, total: 50), mappings: [], warnings: [])
        let result = KnowledgeImportResult(operation: "run", source: "synthetic", planHash: "plan", planned: 120, selected: 50, imported: 50, resumed: 0, skipped: 0, failed: 0, completed: true, progress: KnowledgeImportProgress(completed: 50, remaining: 0, total: 50), mappings: [], warnings: [])
        XCTAssertEqual(KnowledgeImportPresentationPolicy.completionMessage(plan: plan, result: result, offset: 0), "Batch complete (through 50 of 120); inspect the next batch to continue.")
        let failed = KnowledgeImportResult(operation: "run", source: "synthetic", planHash: "plan", planned: 120, selected: 50, imported: 49, resumed: 0, skipped: 0, failed: 1, completed: false, progress: KnowledgeImportProgress(completed: 49, remaining: 1, total: 50), mappings: [], warnings: [])
        XCTAssertTrue(KnowledgeImportPresentationPolicy.completionMessage(plan: plan, result: failed, offset: 0).contains("incomplete"))
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

    func testSourceCorrectionPreservesCapturedRepresentationAndAttributesNewRevisionToUser() throws {
        let source = KnowledgeRecord(
            schemaVersion: 1, id: "source-1", revisionId: "revision-4", kind: .source, scope: .research,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            provenance: KnowledgeProvenance(actor: .connector, source: "raindrop", sessionId: nil, branchId: nil, invocationId: "invoke-1", evidence: []), temporal: nil, relations: [],
            content: .source(KnowledgeSourceContent(title: "Captured", uri: "https://example.com", text: "original readable text", object: KnowledgeObjectRef(hash: String(repeating: "c", count: 64), mediaType: "text/plain", bytes: 21), mediaType: "text/plain", captureDisposition: .complete, annotations: nil, sourcePublishedAt: nil, capturedAt: "2026-01-01T00:00:00Z", origin: "connector", origins: nil, identity: nil, assessment: nil))
        )
        guard case .source(let corrected) = KnowledgeCorrectionPolicy.content(for: source, replacementText: "the corrected interpretation") else { return XCTFail("Expected source correction") }
        XCTAssertEqual(corrected.text, "original readable text")
        XCTAssertEqual(corrected.object?.hash, String(repeating: "c", count: 64))
        XCTAssertEqual(corrected.annotations?.last?.text, "User correction: the corrected interpretation")
        XCTAssertEqual(KnowledgeCorrectionPolicy.provenance(for: source).actor, .user)
        XCTAssertEqual(KnowledgeCorrectionPolicy.provenance(for: source).source, "ios-correction")
        XCTAssertEqual(KnowledgeCorrectionPolicy.provenance(for: source).evidence.last?.revisionId, "revision-4")
    }
}
