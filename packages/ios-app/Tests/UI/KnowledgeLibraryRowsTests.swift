import Foundation
import Testing
@testable import TronMobileCore
@testable import TronMobile

/// Failure modes these cover, written before the implementation: the Library
/// asks the Gateway for the wrong projection and receives full records; a row
/// page is accepted with a stalled cursor or too many rows; a preview batch
/// accepts bytes that do not match the reference it answered; a preview outside
/// the readable bound is fetched anyway; a change event from an older revision
/// refreshes a page that already has it, or an oversized id list is trusted.
@Suite("Library row projection")
@MainActor
struct KnowledgeLibraryRowsTests {
    @Test("the row request carries the sourceRow projection and no saved text")
    func rowRequestShapeAndDecoding() async throws {
        let recorder = LibraryRequestRecorder()
        let client = KnowledgeRPCClient(request: { _, params in
            await recorder.append(params)
            return try JSONDecoder.gateway.decode(JSONValue.self, from: Data(KnowledgeRowFixture.pageJSON(rows: [
                KnowledgeRowFixture.rowJSON(id: "a", title: "First", preview: (KnowledgeRowFixture.hash("a"), "image/jpeg", 1_024), summary: "Current summary"),
                KnowledgeRowFixture.rowJSON(id: "b", title: "Second", admission: "pending"),
            ], nextCursor: "page-2", stateRevision: 12).utf8))
        })
        let page = try await client.sourceRows(scope: .research, sourceAdmission: .retained, limit: 50)
        #expect(page.stateRevision == 12)
        #expect(page.nextCursor == "page-2")
        #expect(page.rows.map(\.id) == ["a", "b"])
        #expect(page.rows[0].preview?.hash == KnowledgeRowFixture.hash("a"))
        #expect(page.rows[0].summary == "Current summary")
        #expect(page.rows[1].admission == .pending)
        let requests = await recorder.values
        let sent = try #require(requests.first?.objectValue)
        #expect(sent["projection"]?.stringValue == "sourceRow")
        #expect(sent["kind"]?.stringValue == "source")
        #expect(sent["ids"] == nil)
        // A row page never carries the saved text the row cannot show.
        #expect(!String(describing: requests.first).contains("text"))
    }

    @Test("an ids request is bounded, unique, and expects no cursor")
    func idsRequest() async throws {
        let client = KnowledgeRPCClient(request: { _, params in
            #expect(params.objectValue?["ids"] != nil)
            return try JSONDecoder.gateway.decode(JSONValue.self, from: Data(KnowledgeRowFixture.pageJSON(rows: [KnowledgeRowFixture.rowJSON(id: "a")]).utf8))
        })
        let page = try await client.sourceRows(ids: ["a"])
        #expect(page.rows.map(\.id) == ["a"])
        await #expect(throws: GatewayFailure.self) { try await client.sourceRows(ids: []) }
        await #expect(throws: GatewayFailure.self) { try await client.sourceRows(ids: ["a", "a"]) }
        await #expect(throws: GatewayFailure.self) {
            try await client.sourceRows(ids: (0...KnowledgeChangeGating.maximumRecordIDs).map { "row-\($0)" })
        }
    }

    @Test("a stalled cursor and an over-long page are rejected")
    func envelopeAdmission() async throws {
        let stalled = KnowledgeRPCClient(request: { _, _ in
            try JSONDecoder.gateway.decode(JSONValue.self, from: Data(KnowledgeRowFixture.pageJSON(rows: [KnowledgeRowFixture.rowJSON()], nextCursor: "page-2").utf8))
        })
        await #expect(throws: GatewayFailure.self) { try await stalled.sourceRows(cursor: "page-2") }

        let tooMany = KnowledgeRPCClient(request: { _, _ in
            let rows = (0...100).map { KnowledgeRowFixture.rowJSON(id: "row-\($0)") }
            return try JSONDecoder.gateway.decode(JSONValue.self, from: Data(KnowledgeRowFixture.pageJSON(rows: rows).utf8))
        })
        await #expect(throws: GatewayFailure.self) { try await tooMany.sourceRows() }
    }

    @Test("a preview batch verifies every item against its own reference")
    func previewBatch() async throws {
        // The Gateway publishes bytes addressed by their own hash, so the
        // fixture's bytes must hash to the reference they answer.
        let bytes = Data(repeating: 7, count: 32)
        let reference = KnowledgeObjectRef(hash: KnowledgePreviewDigest.hex(bytes), mediaType: "image/jpeg", bytes: bytes.count)
        let request = KnowledgePreviewRequest(recordID: "a", revisionID: "revision-1", reference: reference)
        let missing = KnowledgeObjectRef(hash: KnowledgePreviewDigest.hex(Data([1, 2, 3])), mediaType: "image/jpeg", bytes: 3)
        let client = KnowledgeRPCClient(request: { method, _ in
            #expect(method == "knowledge.previews.read")
            let items: [KnowledgePreviewBatchItem] = [
                .init(recordId: "a", hash: reference.hash, base64: bytes.base64EncodedString(), unavailable: nil),
                .init(recordId: "b", hash: missing.hash, base64: nil, unavailable: "missing"),
            ]
            return try JSONDecoder.gateway.decode(JSONValue.self, from: JSONEncoder.gateway.encode(KnowledgePreviewBatchResponse(items: items)))
        })
        let result = try await client.readPreviews([request, KnowledgePreviewRequest(recordID: "b", revisionID: "revision-1", reference: missing)])
        #expect(result.images[reference.hash] == bytes)
        #expect(result.unavailableHashes == [missing.hash])
        await #expect(throws: GatewayFailure.self) { try await client.readPreviews([]) }
    }

    @Test("a preview batch refuses bytes that do not match the answer it received")
    func previewBatchRejectsMismatch() async throws {
        let served = Data(repeating: 7, count: 32)
        let reference = KnowledgeObjectRef(hash: KnowledgePreviewDigest.hex(served), mediaType: "image/jpeg", bytes: 32)
        let request = KnowledgePreviewRequest(recordID: "a", revisionID: "revision-1", reference: reference)
        func client(_ response: [KnowledgePreviewBatchItem]) -> KnowledgeRPCClient {
            KnowledgeRPCClient(request: { _, _ in
                try JSONDecoder.gateway.decode(JSONValue.self, from: JSONEncoder.gateway.encode(KnowledgePreviewBatchResponse(items: response)))
            })
        }
        // Wrong length for the requested reference.
        await #expect(throws: GatewayFailure.self) {
            try await client([.init(recordId: "a", hash: reference.hash, base64: Data(repeating: 1, count: 8).base64EncodedString(), unavailable: nil)]).readPreviews([request])
        }
        // Bytes of the right length that do not hash to the requested reference.
        await #expect(throws: GatewayFailure.self) {
            try await client([.init(recordId: "a", hash: reference.hash, base64: Data(repeating: 3, count: 32).base64EncodedString(), unavailable: nil)]).readPreviews([request])
        }
        // An unknown record that was never asked for.
        await #expect(throws: GatewayFailure.self) {
            try await client([.init(recordId: "other", hash: reference.hash, base64: served.base64EncodedString(), unavailable: nil)]).readPreviews([request])
        }
        // Neither bytes nor a reason.
        await #expect(throws: GatewayFailure.self) {
            try await client([.init(recordId: "a", hash: reference.hash, base64: nil, unavailable: nil)]).readPreviews([request])
        }
        // An invented reason.
        await #expect(throws: GatewayFailure.self) {
            try await client([.init(recordId: "a", hash: reference.hash, base64: nil, unavailable: "whatever")]).readPreviews([request])
        }
    }

    @Test("a preview outside the readable bound is never requested")
    func previewBound() throws {
        let oversized = try KnowledgeRowFixture.row(KnowledgeRowFixture.rowJSON(preview: (KnowledgeRowFixture.hash("a"), "image/jpeg", KnowledgePreviewLimits.maximumBytes + 1)))
        #expect(oversized.previewRequest == nil)
        let empty = try KnowledgeRowFixture.row(KnowledgeRowFixture.rowJSON(preview: (KnowledgeRowFixture.hash("a"), "image/jpeg", 0)))
        #expect(empty.previewRequest == nil)
        let readable = try KnowledgeRowFixture.row(KnowledgeRowFixture.rowJSON(preview: (KnowledgeRowFixture.hash("a"), "image/jpeg", 1_024)))
        #expect(readable.previewRequest?.recordID == "row-1")
        #expect(readable.previewRequest?.reference.bytes == 1_024)
    }

    @Test("row presentation prefers the requested original link")
    func rowPresentation() throws {
        let redirected = try KnowledgeRowFixture.row(KnowledgeRowFixture.rowJSON(uri: "https://resolved.test/page", originalUri: "https://requested.test/item", mediaType: "text/html"))
        #expect(KnowledgeSourceRowPresentationPolicy.originalURL(redirected)?.absoluteString == "https://requested.test/item")
        #expect(KnowledgeSourceRowPresentationPolicy.domain(redirected) == "resolved.test")
        #expect(KnowledgeSourceRowPresentationPolicy.subtitle(redirected) == "resolved.test · Web page")

        // A non-HTTP(S) original link is refused and the canonical URI is used.
        let unsafe = try KnowledgeRowFixture.row(KnowledgeRowFixture.rowJSON(uri: "https://example.test/page", originalUri: "javascript:alert(1)"))
        #expect(KnowledgeSourceRowPresentationPolicy.originalURL(unsafe)?.absoluteString == "https://example.test/page")

        let post = try KnowledgeRowFixture.row(KnowledgeRowFixture.rowJSON(uri: "https://x.com/i/web/status/1"))
        #expect(KnowledgeSourceRowPresentationPolicy.subtitle(post) == "x.com · Post")
        let repository = try KnowledgeRowFixture.row(KnowledgeRowFixture.rowJSON(uri: "https://github.com/a/b"))
        #expect(KnowledgeSourceRowPresentationPolicy.sourceType(repository) == "Repository")
        let pdf = try KnowledgeRowFixture.row(KnowledgeRowFixture.rowJSON(uri: "https://example.test/a", mediaType: "application/pdf"))
        #expect(KnowledgeSourceRowPresentationPolicy.sourceType(pdf) == "PDF")
        // The first letter of each dotted host label, as the record path does.
        #expect(KnowledgeSourceRowPresentationPolicy.thumbnailLetters(repository) == "GC")
    }

    @Test("a changed-row patch keeps every unchanged row in place")
    func patchPolicy() throws {
        let rows = try ["a", "b", "c"].map { try KnowledgeRowFixture.row(KnowledgeRowFixture.rowJSON(id: $0, title: "Old \($0)")) }
        let updatedB = try KnowledgeRowFixture.row(KnowledgeRowFixture.rowJSON(id: "b", title: "New b"))
        // One row changed: only that row's data moves, and order is untouched.
        guard case .patched(let patched) = KnowledgeLibraryPatchPolicy.outcome(rows: rows, changedIDs: ["b"], refreshed: [updatedB]) else {
            Issue.record("A patch of a known row must apply in place"); return
        }
        #expect(patched.map(\.id) == ["a", "b", "c"])
        #expect(patched.map(\.title) == ["Old a", "New b", "Old c"])
        // A changed row that is no longer returned has left the filter.
        guard case .patched(let pruned) = KnowledgeLibraryPatchPolicy.outcome(rows: rows, changedIDs: ["b"], refreshed: []) else {
            Issue.record("A row that left the filter must be removed"); return
        }
        #expect(pruned.map(\.id) == ["a", "c"])
        // A row this page has never seen needs the Gateway's order.
        let unseen = try KnowledgeRowFixture.row(KnowledgeRowFixture.rowJSON(id: "new"))
        #expect(KnowledgeLibraryPatchPolicy.outcome(rows: rows, changedIDs: ["new"], refreshed: [unseen]) == .requiresFirstPage)
    }

    @Test("a change event refreshes only a page that is behind it")
    func changeGating() throws {
        #expect(KnowledgeChangeGating.requiresRefresh(eventRevision: 8, pageRevision: 7))
        #expect(!KnowledgeChangeGating.requiresRefresh(eventRevision: 7, pageRevision: 7))
        #expect(!KnowledgeChangeGating.requiresRefresh(eventRevision: 6, pageRevision: 7))
    }

    @Test("a change event payload is admitted only when it can name rows")
    func changeDecoding() throws {
        func decode(_ json: String) throws -> KnowledgeChanged {
            try JSONDecoder.gateway.decode(KnowledgeChanged.self, from: Data(json.utf8))
        }
        let typed = try decode(#"{"stateRevision":9,"recordIds":["a","b"]}"#)
        #expect(typed.stateRevision == 9)
        #expect(typed.recordIds == ["a", "b"])
        // An empty list cannot name rows; it becomes a first-page refresh.
        #expect(try decode(#"{"stateRevision":9,"recordIds":[]}"#).recordIds == nil)
        #expect(try decode(#"{"stateRevision":9}"#).recordIds == nil)
        #expect(throws: (any Error).self) { try decode(#"{"stateRevision":-1}"#) }
        #expect(throws: (any Error).self) {
            let ids = (0...KnowledgeChangeGating.maximumRecordIDs).map { "\"row-\($0)\"" }.joined(separator: ",")
            return try decode(#"{"stateRevision":9,"recordIds":[\#(ids)]}"#)
        }
        #expect(throws: (any Error).self) { try decode(#"{"stateRevision":9,"recordIds":[""]}"#) }
    }

    @Test("the change topic is recognized, typed, and coalesced")
    func changeEventProjection() throws {
        struct Params: Encodable { let stateRevision: Int; let recordIds: [String]? }
        let event = GatewayEvent(type: "event", topic: "knowledge.changed", sessionId: nil,
                                 payload: try JSONDecoder.gateway.decode(JSONValue.self, from: JSONEncoder.gateway.encode(Params(stateRevision: 4, recordIds: ["a"]))))
        guard case .knowledgeChanged(let change) = event.preparation else {
            Issue.record("knowledge.changed must decode into its typed preparation")
            return
        }
        #expect(change.stateRevision == 4)
        #expect(change.recordIds == ["a"])
        #expect(GatewayDiagnosticTopicAdmission.admit("knowledge.changed") == "knowledge.changed")
    }

    @Test("a superseded or cancelled query is never published")
    func searchDebounce() async throws {
        let debouncer = KnowledgeSearchDebouncer(delay: .milliseconds(25))
        var applied: [String] = []
        debouncer.schedule("a") { applied.append($0) }
        debouncer.schedule("agents") { applied.append($0) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(applied == ["agents"])
        debouncer.schedule("later") { applied.append($0) }
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(150))
        #expect(applied == ["agents"])
    }

    @Test("a short query is presented as no query")
    func searchPolicy() {
        #expect(KnowledgeSearchPolicy.effectiveQuery("") == "")
        #expect(KnowledgeSearchPolicy.effectiveQuery(" a ") == "")
        #expect(KnowledgeSearchPolicy.effectiveQuery("ab") == "ab")
        #expect(KnowledgeSearchPolicy.effectiveQuery("  agents  ") == "agents")
        #expect(!KnowledgeSearchPolicy.admitsQuery("a"))
        #expect(KnowledgeSearchPolicy.admitsQuery("ab"))
    }
}

private actor LibraryRequestRecorder {
    private(set) var values: [JSONValue] = []
    func append(_ value: JSONValue) { values.append(value) }
}
