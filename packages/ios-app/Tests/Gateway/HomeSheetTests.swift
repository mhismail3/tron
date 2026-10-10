import XCTest
@testable import TronMobile
import TronMobileCore

/// Failure modes: wrong physical identity, oversized or mixed pages, projection
/// mistaken for canonical evidence, and stale publication.
@MainActor
final class HomeSheetTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    private func evidence(index: Int = 0) -> JSONValue {
        .object(["index": .number(Double(index)), "sessionId": .string("source"),
                 "entryId": .string("entry"), "sourceDigest": .string(digest)])
    }

    private func page(revision: String? = nil, text: String = "projection") -> JSONValue {
        .object(["homeId": .string("home"), "revision": .string(revision ?? digest), "totalItems": .number(1),
            "items": .array([.object(["index": .number(0), "kind": .string("user"), "attribution": .string("user"),
                "evidence": evidence(), "projection": .object(["format": .string("memory-projection"), "text": .string(text),
                    "omitted": .bool(false), "omissions": .array([])]), "summary": .null])])])
    }

    func testMemoryPageRejectsOversizedMixedRevisionAndWrongAttribution() throws {
        XCTAssertThrowsError(try HomeMemoryPageDTO.decode(page(text: String(repeating: "x", count: 4097)), revision: nil))
        XCTAssertThrowsError(try HomeMemoryPageDTO.decode(page(), revision: String(repeating: "b", count: 64)))
        var wrong = try XCTUnwrap(page().objectValue)
        var item = try XCTUnwrap(wrong["items"]?.arrayValue?.first?.objectValue)
        item["attribution"] = .string("assistant")
        wrong["items"] = .array([.object(item)])
        XCTAssertThrowsError(try HomeMemoryPageDTO.decode(.object(wrong), revision: nil))
        let decoded = try HomeMemoryPageDTO.decode(page(), revision: nil)
        XCTAssertEqual(decoded.items[0].projection.text, "projection")
        XCTAssertNil(decoded.items[0].summary)
    }

    func testMemoryByteAdmissionUsesGatewayJSONEncoding() throws {
        var value = page().objectValue!
        let template = value["items"]!.arrayValue!.first!.objectValue!
        value["totalItems"] = .number(20)
        value["items"] = .array((0..<20).map { index in
            var row = template
            row["index"] = .number(Double(index))
            var source = evidence(index: index).objectValue!
            source["entryId"] = .string("entry-\(index)")
            row["evidence"] = .object(source)
            row["projection"] = .object(["format": .string("memory-projection"),
                "text": .string(String(repeating: "/", count: 4096)), "omitted": .bool(false), "omissions": .array([])])
            return .object(row)
        })
        let wirePage = JSONValue.object(value)
        XCTAssertLessThan(try JSONEncoder.gateway.encode(wirePage).count, 128 * 1024)
        XCTAssertEqual(try HomeMemoryPageDTO.decode(wirePage, revision: nil).items.count, 20)
    }

    func testContinuationCannotReplayAnotherHomeOrEarlierRows() throws {
        XCTAssertThrowsError(try HomeMemoryPageDTO.decode(page(), continuation: .init(cursor: "cursor", revision: digest, homeId: "other", afterIndex: -1)))
        XCTAssertThrowsError(try HomeMemoryPageDTO.decode(page(), continuation: .init(cursor: "cursor", revision: digest, homeId: "home", afterIndex: 0)))
    }

    func testEvidenceRequiresCanonicalFormatExactIdentityAndProgressingOffsets() throws {
        let identity = try evidence().decode(HomeMemoryEvidenceDTO.self)
        // `metadata` is not read by the app, so a Gateway value of any shape must still decode.
        var response: [String: JSONValue] = ["format": .string("canonical-history"), "evidence": evidence(),
            "text": .string("canonical original"), "offset": .number(0), "totalCharacters": .number(18), "metadata": .string("future shape")]
        XCTAssertEqual(try HomeMemoryEvidencePageDTO.decode(.object(response), evidence: identity, offset: 0).text, "canonical original")
        for change in [("format", JSONValue.string("memory-projection")), ("evidence", evidence(index: 1)),
                       ("offset", .number(1)), ("nextOffset", .number(0)), ("text", .string(String(repeating: "x", count: 24_001)))] {
            var wrong = response
            wrong[change.0] = change.1
            XCTAssertThrowsError(try HomeMemoryEvidencePageDTO.decode(.object(wrong), evidence: identity, offset: 0))
        }
        response["totalCharacters"] = .number(100)
        XCTAssertThrowsError(try HomeMemoryEvidencePageDTO.decode(.object(response), evidence: identity, offset: 0), "truncated text must supply continuation")
    }

    func testStatusAdmitsMemoryModelSpendAndRejectsInvalidMetadata() throws {
        var status = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"phase":"ready","activation":{"available":false},"readiness":{"ready":true,"gaps":[]},"recovery":{"action":"none"},"available":true,"enabled":true,"live":false,"sessionPresent":true,"memory":{"configured":true,"open":true}}"#.utf8)).objectValue!
        status["memory"] = .object(["configured": .bool(true), "open": .bool(true), "spentTokens": .number(42),
                                    "model": .object(["provider": .string("fixture"), "id": .string(String(repeating: "m", count: 250))])])
        let value = try HomeStatusDTO.decode(.object(status))
        XCTAssertEqual(value.memory.model, ModelRef(provider: "fixture", id: String(repeating: "m", count: 250)))
        XCTAssertEqual(value.memory.spentTokens, 42)
        status["memory"] = .object(["configured": .bool(true), "open": .bool(true), "spentTokens": .number(-1)])
        XCTAssertThrowsError(try HomeStatusDTO.decode(.object(status)))
    }

    // Failure mode: chat-model and chapter metadata out of protocol bounds is
    // admitted into the Manage Home sheet, or their absence (an older Gateway)
    // stops the whole status from decoding.
    func testStatusAdmitsChapterAndChatModelWithinBoundsOnly() throws {
        var status = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"phase":"ready","activation":{"available":false},"readiness":{"ready":true,"gaps":[]},"recovery":{"action":"none"},"available":true,"enabled":true,"live":false,"sessionPresent":true,"memory":{"configured":true,"open":true}}"#.utf8)).objectValue!
        let absent = try HomeStatusDTO.decode(.object(status))
        XCTAssertNil(absent.model)
        XCTAssertNil(absent.chapter)
        status["model"] = .object(["provider": .string("fixture"), "id": .string("chat-model")])
        status["chapter"] = .object(["count": .number(3), "currentBytes": .number(480),
                                     "currentEntries": .number(12), "recoveryDecision": .string("reserved")])
        let value = try HomeStatusDTO.decode(.object(status))
        XCTAssertEqual(value.model, ModelRef(provider: "fixture", id: "chat-model"))
        XCTAssertEqual(value.chapter, HomeStatusDTO.Chapter(count: 3, currentBytes: 480, currentEntries: 12, recoveryDecision: .reserved))
        for invalid in [JSONValue.object(["count": .number(0), "recoveryDecision": .string("none")]),
                        .object(["count": .number(1), "currentBytes": .number(-1), "recoveryDecision": .string("none")]),
                        .object(["count": .number(1), "recoveryDecision": .string("future-decision")])] {
            status["chapter"] = invalid
            XCTAssertThrowsError(try HomeStatusDTO.decode(.object(status)))
        }
        status["chapter"] = .null
        status["model"] = .object(["provider": .string(""), "id": .string("chat-model")])
        XCTAssertThrowsError(try HomeStatusDTO.decode(.object(status)))
    }

    private func chapterList(chapters: [JSONValue]) -> JSONValue {
        .object(["homeId": .string("home"), "generation": .number(2), "enabled": .bool(true),
                 "limits": .object(["softBytes": .number(25_165_824), "softEntries": .number(50_000),
                                    "hardBytes": .number(209_715_200), "hardEntries": .number(100_000)]),
                 "chapters": .array(chapters)])
    }

    private func chapter(_ ordinal: Int, state: String, bytes: Int? = nil, entries: Int? = nil, sealedAt: String? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["sessionId": .string("chapter-\(ordinal)"), "ordinal": .number(Double(ordinal)),
            "state": .string(state), "createdAt": .string("2026-01-0\(ordinal)T00:00:00Z"),
            "activationStarted": .bool(true), "sessionPresent": .bool(true)]
        if let bytes { value["bytes"] = .number(Double(bytes)) }
        if let entries { value["entries"] = .number(Double(entries)) }
        if let sealedAt { value["sealedAt"] = .string(sealedAt) }
        return .object(value)
    }

    // Failure modes (#740): protocol drift admitted into the Chapters sheet, an
    // unmeasured chapter read as zero, or an out-of-order/empty ledger accepted.
    func testChapterListAdmitsLedgerAndRejectsDrift() throws {
        let list = try HomeChapterListDTO.decode(chapterList(chapters: [
            chapter(1, state: "sealed", bytes: 25_165_824, entries: 50_001, sealedAt: "2026-01-02T00:00:00Z"),
            chapter(2, state: "reserved"),
        ]))
        XCTAssertEqual(list.chapters.count, 2)
        XCTAssertEqual(list.chapters[0].bytes, 25_165_824)
        XCTAssertNil(list.chapters[1].bytes, "an unmeasured chapter must stay unmeasured, never zero")
        XCTAssertThrowsError(try HomeChapterListDTO.decode(chapterList(chapters: [])))
        XCTAssertThrowsError(try HomeChapterListDTO.decode(chapterList(chapters: [chapter(2, state: "sealed"), chapter(1, state: "active")])),
                             "ledger order is the Gateway's; a reordered list is drift")
        XCTAssertThrowsError(try HomeChapterListDTO.decode(chapterList(chapters: [chapter(1, state: "future-state")])))
        XCTAssertThrowsError(try HomeChapterListDTO.decode(chapterList(chapters: [chapter(1, state: "active", bytes: -1)])))
        var inverted = chapterList(chapters: [chapter(1, state: "active")]).objectValue!
        inverted["limits"] = .object(["softBytes": .number(100), "softEntries": .number(100),
                                      "hardBytes": .number(50), "hardEntries": .number(50)])
        XCTAssertThrowsError(try HomeChapterListDTO.decode(.object(inverted)))
    }

    func testChapterPresentationNamesUnmeasuredSizesAndLimits() throws {
        let list = try HomeChapterListDTO.decode(chapterList(chapters: [
            chapter(1, state: "sealed", bytes: 25_165_824, entries: 50_001, sealedAt: "2026-01-02T00:00:00Z"),
            chapter(2, state: "active", bytes: 480, entries: 12),
            chapter(3, state: "reserved"),
        ]))
        XCTAssertEqual(HomeChapterPresentation.sizeLine(list.chapters[2], limits: list.limits), "Not measured")
        XCTAssertTrue(HomeChapterPresentation.sizeLine(list.chapters[1], limits: list.limits).hasSuffix("% of soft limit"))
        XCTAssertTrue(HomeChapterPresentation.sizeLine(list.chapters[0], limits: list.limits).hasSuffix("% of hard limit"),
                      "a chapter at its soft limit is measured against the hard limit")
        XCTAssertTrue(HomeChapterPresentation.dateRange(list.chapters[0]).contains("\u{2013}"))
        XCTAssertTrue(HomeChapterPresentation.dateRange(list.chapters[1]).hasPrefix("Since "))
        XCTAssertEqual(HomeChapterPresentation.stateLabel(list.chapters[2].state), "Reserved")
        XCTAssertEqual(HomeChapterPresentation.manageSubtitle(.init(count: 3, currentBytes: nil, currentEntries: nil, recoveryDecision: .reserved)),
                       "3 chapters · Successor reserved")
    }

    func testNewerPageOwnsLoadingResultAndError() async throws {
        let coordinator = PresentationActivityCoordinator()
        let token = PresentationSurfaceToken(id: "memory", generation: UUID())
        coordinator.register(token, parent: nil)
        let identity = HomeSheetReadIdentity(profileID: "p", connectionID: 1, lifecycleGeneration: 1, surfaceToken: token)
        let owner = HomeSheetReadOwner()
        let started = expectation(description: "old request started")
        var resume: CheckedContinuation<HomeSheetContent, Error>?
        let old = Task {
            await owner.load(requestID: UUID(), identity: identity, coordinator: coordinator, isCurrent: { true }) {
                try await withCheckedThrowingContinuation { resume = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        await owner.load(requestID: UUID(), identity: identity, coordinator: coordinator, isCurrent: { true }) {
            .memory(try HomeMemoryPageDTO.decode(self.page(), revision: nil))
        }
        resume?.resume(throwing: NSError(domain: "old error", code: 1))
        await old.value
        guard case .loaded(_, .memory(let page)) = owner.state else { return XCTFail("stale error replaced latest page") }
        XCTAssertEqual(page.items[0].projection.text, "projection")
        owner.retire()
    }

    /// A rerun of the same request (same identity, new `.task` lifetime) must not
    /// let its cancelled predecessor retire the load that replaced it while it is in flight.
    func testCancelledRerunOfSameRequestCannotRetireNewerLoad() async throws {
        let coordinator = PresentationActivityCoordinator()
        let token = PresentationSurfaceToken(id: "memory", generation: UUID())
        coordinator.register(token, parent: nil)
        let identity = HomeSheetReadIdentity(profileID: "p", connectionID: 1, lifecycleGeneration: 1, surfaceToken: token)
        let owner = HomeSheetReadOwner()
        let requestID = UUID()
        let firstStarted = expectation(description: "first run started")
        let rerunStarted = expectation(description: "rerun started")
        var resumes: [CheckedContinuation<HomeSheetContent, Error>] = []
        func gatedFetch(_ started: XCTestExpectation) async throws -> HomeSheetContent {
            try await withCheckedThrowingContinuation { resumes.append($0); started.fulfill() }
        }
        let first = Task {
            await owner.load(requestID: requestID, identity: identity, coordinator: coordinator, isCurrent: { true }) {
                try await gatedFetch(firstStarted)
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        first.cancel()
        let rerun = Task {
            await owner.load(requestID: requestID, identity: identity, coordinator: coordinator, isCurrent: { true }) {
                try await gatedFetch(rerunStarted)
            }
        }
        await fulfillment(of: [rerunStarted], timeout: 1)
        // The cancelled run returns late while the rerun is still the installed load.
        resumes[0].resume(returning: .memory(try HomeMemoryPageDTO.decode(page(), revision: nil)))
        await first.value
        var rerunStillLoading = false
        if case .loading(let pending, .none) = owner.state, pending.requestID == requestID { rerunStillLoading = true }
        resumes[1].resume(returning: .memory(try HomeMemoryPageDTO.decode(page(), revision: nil)))
        await rerun.value
        guard rerunStillLoading else { return XCTFail("cancelled rerun retired the load that replaced it") }
        guard case .loaded(let read, .memory) = owner.state else { return XCTFail("rerun did not publish its own result") }
        XCTAssertEqual(read.requestID, requestID)
        owner.retire()
        coordinator.retire(token)
    }

    /// A late answer must not publish once its sheet is dismissed, covered, or its
    /// profile/connection is no longer current; a late failure is held to the same rule.
    func testRetiredOrChangedAuthorityRejectsLateSuccessAndFailure() async throws {
        for transition in ["dismiss", "cover", "not-current", "not-current-failure"] {
            let coordinator = PresentationActivityCoordinator()
            let token = PresentationSurfaceToken(id: "memory", generation: UUID())
            coordinator.register(token, parent: nil)
            let identity = HomeSheetReadIdentity(profileID: "p", connectionID: 1, lifecycleGeneration: 1, surfaceToken: token)
            let owner = HomeSheetReadOwner()
            var current = true
            let started = expectation(description: transition)
            var resume: CheckedContinuation<HomeSheetContent, Error>?
            let task = Task {
                await owner.load(requestID: UUID(), identity: identity, coordinator: coordinator, isCurrent: { current }) {
                    try await withCheckedThrowingContinuation { resume = $0; started.fulfill() }
                }
            }
            await fulfillment(of: [started], timeout: 1)
            switch transition {
            case "dismiss": owner.retire(); coordinator.retire(token)
            case "cover": coordinator.register(.init(id: "child", generation: UUID()), parent: token)
            default: current = false
            }
            if transition == "not-current-failure" { resume?.resume(throwing: NSError(domain: "late error", code: 1)) }
            else { resume?.resume(returning: .memory(try HomeMemoryPageDTO.decode(page(), revision: nil))) }
            await task.value
            guard case .idle = owner.state else { return XCTFail("\(transition) published a retired read") }
            owner.retire()
            coordinator.retire(token)
        }
    }
}
