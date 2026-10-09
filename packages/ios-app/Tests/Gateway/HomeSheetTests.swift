import XCTest
@testable import TronMobile
import TronMobileCore

/// Failure modes written in the step-6 handoff: wrong physical identity, oversized
/// or mixed pages, projection mistaken for canonical evidence, stale publication.
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
        var response: [String: JSONValue] = ["format": .string("canonical-history"), "evidence": evidence(),
            "text": .string("canonical original"), "offset": .number(0), "totalCharacters": .number(18), "metadata": .object([:])]
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

    func testRetiredOrChangedAuthorityRejectsLateSuccessAndFailure() async throws {
        for transition in ["dismiss", "cover", "profile", "connection", "background"] {
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
            if transition == "background" { resume?.resume(throwing: NSError(domain: "late error", code: 1)) }
            else { resume?.resume(returning: .memory(try HomeMemoryPageDTO.decode(page(), revision: nil))) }
            await task.value
            guard case .idle = owner.state else { return XCTFail("\(transition) published a retired read") }
            owner.retire()
            coordinator.retire(token)
        }
    }
}
