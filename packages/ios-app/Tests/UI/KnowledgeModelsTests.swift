import XCTest
@testable import TronMobile

private actor CoverageTestRecorder {
    var calls: [String?] = []
    var shouldFail = true
    func append(_ cursor: String?) { calls.append(cursor) }
    func takeCalls() -> [String?] { calls }
    func consumeFailure() -> Bool { defer { shouldFail = false }; return shouldFail }
}

final class KnowledgeModelsTests: XCTestCase {
    @MainActor
    func testConnectorStatusCarriesExactConnectionRoute() async throws {
        var captured: (String, JSONValue)?
        let client = KnowledgeRPCClient(request: { method, params, _ in
            captured = (method, params)
            return .object(["connector": .string("raindrop"), "connectionId": .string("account-two"), "configured": .bool(true), "enabled": .bool(true), "health": .string("setup-required"), "credentialAvailability": .string("unknown"), "providerIdentity": .string("unknown"), "accountId": .string("202"), "scope": .string("0"), "remaining": .number(0), "pending": .number(0), "paidBudgetCents": .number(0), "allowWrites": .bool(false), "recurringApproved": .bool(false), "paidAccessApproved": .bool(false)])
        })
        _ = try await client.connectorStatus("raindrop", connectionID: "account-two")
        XCTAssertEqual(captured?.0, "knowledge.connector.status")
        XCTAssertEqual(captured?.1.objectValue?["connector"], .string("raindrop"))
        XCTAssertEqual(captured?.1.objectValue?["connectionId"], .string("account-two"))
        XCTAssertEqual(captured?.1.objectValue?.count, 2)
    }

    @MainActor
    func testAcceptedConnectorMutationCarriesExactConnectionAndSettlesAfterOwnerResponse() async throws {
        let socket = ScriptedGatewaySocket()
        let gateway = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory, clock: .continuous)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let lifecycle = GatewayLifecycleCoordinator(
            client: gateway, profiles: GatewayProfileStore(defaults: defaults), clock: .continuous,
            reconnectDelayPolicy: .standard, uuidSource: .random, pairer: GatewayPairer(),
            pairingCommit: { _, _ in }, profileTokenLookup: { _ in nil }
        )
        let executor = ConfirmedMutationExecutor(client: gateway, lifecycle: lifecycle, clock: .continuous, performanceSignposts: RecordingPerformanceSignposts())
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8))
        try await lifecycle.connectHosted(profile: GatewayProfile(id: "fixture", label: "Fixture", host: "gateway.test", port: 9847, machineId: "machine", deviceId: "device"), token: "token")
        let client = KnowledgeRPCClient(request: { method, parameters, timeout in
            try await gateway.requestValue(method, parameters, timeout: timeout)
        }, mutationExecutor: executor, uuidSource: UUIDSource(next: { UUID(uuidString: "00000000-0000-4000-8000-000000000001")! }))
        let task = Task { try await client.runConnector("raindrop", connectionID: "account-two", dryRun: true, limit: 10) }
        var request: JSONValue?
        var requestID: String?
        for _ in 0..<100 {
            for frame in await socket.sentFrames() {
                if let value = try? JSONDecoder.gateway.decode(JSONValue.self, from: frame), value.objectValue?["method"]?.stringValue == "knowledge.connector.run" {
                    request = value; requestID = value.objectValue?["id"]?.stringValue; break
                }
            }
            if request != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let admittedRequest = try XCTUnwrap(request)
        let id = try XCTUnwrap(requestID)
        XCTAssertEqual(admittedRequest.objectValue?["params"]?.objectValue?["connectionId"], .string("account-two"))
        XCTAssertEqual(admittedRequest.objectValue?["params"]?.objectValue?["connector"], .string("raindrop"))
        XCTAssertEqual(admittedRequest.objectValue?["params"]?.objectValue?["commandId"], .string("00000000-0000-4000-8000-000000000001"))
        await socket.enqueue(try! JSONEncoder.gateway.encode(JSONValue.object(["type": .string("response"), "id": .string(id), "ok": .bool(true), "result": .object(["dryRun": .bool(true), "connector": .string("raindrop"), "discovered": .number(0), "captured": .number(0), "pending": .number(0), "remaining": .number(0), "health": .string("ready"), "partial": .number(0), "error": .null])])) )
        let result = try await task.value
        XCTAssertEqual(result.connector, "raindrop")
        XCTAssertTrue(result.dryRun)
    }

    func testConnectorStatusKeepsConnectionIdentityAndDoesNotTreatSetupAsReady() throws {
        let data = Data(#"{"connector":"raindrop","connectionId":"account-two","configured":true,"enabled":true,"health":"setup-required","credentialAvailability":"unknown","providerIdentity":"unknown","accountId":"202","scope":"0","lastRunAt":null,"lastError":null,"remaining":0,"pending":0,"paidBudgetCents":0,"allowWrites":false,"recurringApproved":false,"paidAccessApproved":false}"#.utf8)
        let status = try JSONDecoder().decode(KnowledgeConnectorStatus.self, from: data)
        XCTAssertEqual(status.connectionId, "account-two")
        XCTAssertFalse(status.available)
        XCTAssertEqual(status.detail, "Provider admission is not established.")
    }

    func testObservationPresentationSeparatesStatementDateAndTechnicalEvidence() throws {
        let record = KnowledgeObservationFixture.record()
        let presentation = try XCTUnwrap(KnowledgeObservationPresentation(record: record))
        XCTAssertEqual(presentation.statement, "The user prefers concise explanations.")
        XCTAssertEqual(presentation.scope, "Personal")
        XCTAssertEqual(presentation.date, GatewayTimestamp.parse("2026-01-01T09:30:00Z"))
        XCTAssertNotEqual(presentation.observedAt, record.updatedAt, "Correcting a record must not redate its observation")
        XCTAssertEqual(presentation.sessionID, "fixture-session")
        XCTAssertEqual(presentation.entryID, "fixture-first", "The single session action retains the exact originating entry")
        XCTAssertEqual(presentation.recordMetadata.first { $0.title == "Revision" }?.value, "fixture-revision")
        XCTAssertEqual(presentation.sourceMetadata.first { $0.title == "Digest" }?.value, String(repeating: "a", count: 64))
        XCTAssertEqual(presentation.sourceMetadata.first { $0.title == "Entries" }?.value, "fixture-first, fixture-last")
        XCTAssertEqual(presentation.observerMetadata.first { $0.title == "Model" }?.value, "fixture/model")
        let item = try XCTUnwrap(presentation.observation.items.first)
        XCTAssertEqual(presentation.itemMetadata(item).map(\.value), ["User", "Qualified", "2026-01-01T09:30:00Z"])
        XCTAssertEqual(presentation.record.provenance.evidence.count, 2, "Simplifying evidence rows must not discard canonical citations")
    }

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

    func testGlobalObservationGrantIsExplicitAndPreservesSelectedScopesAndExclusions() throws {
        let selected = Data(#"{"sessionIds":["selected-session"],"projectIds":["selected-project"],"excludedSessionIds":["private-session"],"excludedProjectIds":["private-project"]}"#.utf8)
        var eligibility = try JSONDecoder().decode(KnowledgeEligibility.self, from: selected)
        XCTAssertNil(eligibility.allSessions)
        eligibility.allSessions = true
        let global = try JSONValue.encode(eligibility)
        XCTAssertEqual(global.objectValue?["allSessions"], .bool(true))
        let decoded = try global.decode(KnowledgeEligibility.self)
        XCTAssertEqual(decoded.sessionIds, ["selected-session"])
        XCTAssertEqual(decoded.projectIds, ["selected-project"])
        XCTAssertEqual(decoded.excludedSessionIds, ["private-session"])
        XCTAssertEqual(decoded.excludedProjectIds, ["private-project"])
        eligibility.allSessions = nil
        XCTAssertNil(try JSONValue.encode(eligibility).objectValue?["allSessions"])
    }

    @MainActor
    func testGlobalConfigurationCannotBeSentToAGatewayWithoutGlobalAdmission() async {
        var requests = 0
        let client = KnowledgeRPCClient(request: { _, _, _ in requests += 1; return .null })
        let config = KnowledgeConfig(schemaVersion: 1, revision: 0,
                                     eligibility: KnowledgeEligibility(allSessions: true, sessionIds: [], projectIds: [], excludedSessionIds: [], excludedProjectIds: []),
                                     observation: KnowledgeObservationLimits(enabled: true, model: "fixture/model", maxInputChars: 48_000, maxOutputChars: 8_000, timeoutMs: 30_000, maxAttempts: 1),
                                     maximumSearchResults: 50, currentInterests: [])
        do {
            _ = try await client.configure(config, capabilities: ["knowledge.v1"])
            XCTFail("Global selection must not be silently ignored by an unsupported Gateway")
        } catch let error as GatewayFailure {
            XCTAssertEqual(error.code, "unsupported")
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(requests, 0)
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
    func testCoverageRequestCarriesTheDispositionFilterAndAdmitsOnlyItsRows() async throws {
        let cut = { (id: String, disposition: String) in JSONValue.object([
            "schemaVersion": .number(1), "id": .string(id), "revisionId": .string("\(id)-revision"),
            "range": .object(["sessionId": .string("session"), "fromEntryId": .string("from"), "toEntryId": .string("to"),
                              "entryIds": .array([.string("from")]), "entryDigest": .string(String(repeating: "a", count: 64))]),
            "disposition": .string(disposition), "groupRevisionIds": .array([]), "recordedAt": .string("2026-01-01T00:00:00Z")]) }
        var requests: [JSONValue] = []
        let client = KnowledgeRPCClient(request: { method, parameters, _ in
            XCTAssertEqual(method, "knowledge.observation.coverage")
            requests.append(parameters)
            return .object(["coverage": .array([cut("cut-1", "failed")]), "stateRevision": .number(4)])
        })
        let page = try await client.coverage(limit: 400, dispositions: KnowledgeCoveragePresentationPolicy.attentionDispositions)
        XCTAssertEqual(page.coverage.map(\.id), ["cut-1"])
        XCTAssertEqual(requests.first?.objectValue?["limit"]?.intValue, 100, "The Gateway page bound stays authoritative")
        XCTAssertEqual(requests.first?.objectValue?["dispositions"]?.arrayValue?.compactMap(\.stringValue), ["pending", "failed", "unavailable"])
        XCTAssertNil(requests.first?.objectValue?["cursor"]?.stringValue)

        // A Gateway that ignores the filter must not publish settled rows as
        // cuts needing attention.
        let unfiltered = KnowledgeRPCClient(request: { _, _, _ in
            .object(["coverage": .array([cut("cut-2", "observed")]), "stateRevision": .number(4)])
        })
        do {
            _ = try await unfiltered.coverage(dispositions: KnowledgeCoveragePresentationPolicy.attentionDispositions)
            XCTFail("A page outside the requested dispositions must be rejected")
        } catch let failure as GatewayFailure {
            XCTAssertEqual(failure.code, "invalid_response")
        }
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
                let text = offset == 0 ? "first-" : "second"
                let bytes = Data(text.utf8).base64EncodedString()
                return .object([
                    "hash": .string(hash), "mediaType": .string("text/plain"),
                    "bytes": .number(Double(text.utf8.count)), "totalBytes": .number(12),
                    "offset": .number(Double(offset)), "nextOffset": offset == 0 ? .number(6) : .null,
                    "base64": .string(bytes)
                ])
            default:
                throw GatewayFailure(code: "unexpected", message: method, retryable: false, details: nil)
            }
        })

        let page = try await client.list(limit: 100)
        XCTAssertEqual(page.nextCursor, "page-2")
        XCTAssertEqual(requests.first?.0, "knowledge.list")
        _ = try await client.list(kind: .source, includeArchived: true, includePending: true, limit: 50)
        XCTAssertEqual(requests.last?.1.objectValue?["includeArchived"], .bool(true))
        XCTAssertEqual(requests.last?.1.objectValue?["includePending"], .bool(true))
        let object = KnowledgeObjectRef(hash: hash, mediaType: "text/plain", bytes: 12)
        let archivedResult = try await client.readObject(object, recordID: "source-1", revisionID: "revision-1", includeArchived: true, offset: 0)
        XCTAssertNotNil(archivedResult)
        XCTAssertEqual(requests.last?.1.objectValue?["includeArchived"], .bool(true))
        let firstResult = try await client.readObject(object, recordID: "source-1", revisionID: "revision-1", offset: 0)
        let first: KnowledgeObjectRead = try XCTUnwrap(firstResult)
        let nextOffset: Int = try XCTUnwrap(first.nextOffset)
        let secondResult = try await client.readObject(object, recordID: "source-1", revisionID: "revision-1", offset: nextOffset)
        let second: KnowledgeObjectRead = try XCTUnwrap(secondResult)
        XCTAssertEqual(Data(base64Encoded: first.base64).flatMap { String(data: $0, encoding: .utf8) }, "first-")
        XCTAssertEqual(Data(base64Encoded: second.base64).flatMap { String(data: $0, encoding: .utf8) }, "second")
        XCTAssertEqual(requests.compactMap { $0.1.objectValue?["offset"]?.intValue }, [0, 0, 6])
        XCTAssertEqual(requests.compactMap { $0.1.objectValue?["recordId"]?.stringValue }, ["source-1", "source-1", "source-1"])
        XCTAssertEqual(requests.compactMap { $0.1.objectValue?["revisionId"]?.stringValue }, ["revision-1", "revision-1", "revision-1"])
    }

    @MainActor
    func testKnowledgeRPCRejectsMalformedObjectEnvelope() async {
        let hash = String(repeating: "c", count: 64)
        let client = KnowledgeRPCClient(request: { method, _, _ in
            XCTAssertEqual(method, "knowledge.object.read")
            return .object(["hash": .string(hash), "mediaType": .string("text/plain"), "bytes": .number(4), "totalBytes": .number(6), "offset": .number(0), "nextOffset": .null, "base64": .string(Data("four".utf8).base64EncodedString())])
        })
        do {
            _ = try await client.readObject(KnowledgeObjectRef(hash: hash, mediaType: "text/plain", bytes: 6), recordID: "source", revisionID: "revision")
            XCTFail("Malformed final chunk must be rejected")
        } catch let error as GatewayFailure {
            XCTAssertEqual(error.code, "invalid_response")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPartialUTF8TextRemainsTextualUntilTheNextChunkArrives() {
        let prefix = Data([0x63, 0x61, 0x66, 0xC3])
        let rendered = KnowledgeObjectPresentationPolicy.renderedText(prefix, mediaType: "text/plain", label: "source")
        XCTAssertFalse(rendered.contains("Binary"))
        XCTAssertTrue(rendered.hasPrefix("caf"))
        XCTAssertEqual(KnowledgeObjectPresentationPolicy.renderedText(Data([0x00, 0x01]), mediaType: "application/octet-stream", label: "source"), "Binary source (2 bytes loaded)")
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

    @MainActor
    func testCoverageContinuationAdvancesAcrossARevisionChange() async {
        let identity = KnowledgePresentationIdentity(profileID: "fixture", lifecycleGeneration: 1, connectionID: 1)
        let range = KnowledgeObservationRange(sessionId: "session", branchId: nil, fromEntryId: "from", toEntryId: "to", entryIds: ["from"], entryDigest: String(repeating: "a", count: 64), projectId: nil, invocationIds: nil)
        let store = KnowledgeCoveragePresentationStore()
        let recorder = CoverageTestRecorder()
        await store.load(identity: identity, request: { cursor in
            await recorder.append(cursor)
            return KnowledgeCoveragePage(coverage: [Self.syntheticCut("cut-pending", .pending, range: range)], stateRevision: 1, nextCursor: "page-2")
        }, isCurrent: { true })
        await store.loadMore(identity: identity, request: { cursor in
            await recorder.append(cursor)
            // The ledger advanced while the next page was in flight and
            // re-recorded the already-loaded cut with a new disposition.
            return KnowledgeCoveragePage(coverage: [Self.syntheticCut("cut-pending", .failed, range: range), Self.syntheticCut("cut-unavailable", .unavailable, range: range)], stateRevision: 2, nextCursor: nil)
        }, isCurrent: { true })
        let recordedCalls = await recorder.takeCalls()
        XCTAssertEqual(recordedCalls, [nil, "page-2"], "Paging must advance instead of restarting at the head when the ledger changes")
        XCTAssertEqual(store.cuts.map(\.id), ["cut-pending", "cut-unavailable"])
        XCTAssertEqual(store.cuts.first?.disposition, .failed, "A re-recorded cut replaces its retained copy")
        XCTAssertNil(store.nextCursor)
        XCTAssertEqual(store.stateRevision, 2)

        let retryStore = KnowledgeCoveragePresentationStore()
        let retryRecorder = CoverageTestRecorder()
        await retryStore.load(identity: identity, request: { _ in
            if await retryRecorder.consumeFailure() { throw GatewayFailure(code: "temporary", message: "fixture retry", retryable: true, details: nil) }
            return KnowledgeCoveragePage(coverage: [Self.syntheticCut("retry", .failed, range: range)], stateRevision: 3, nextCursor: nil)
        }, isCurrent: { true })
        XCTAssertNotNil(retryStore.error)
        await retryStore.load(identity: identity, request: { _ in
            KnowledgeCoveragePage(coverage: [Self.syntheticCut("retry", .failed, range: range)], stateRevision: 3, nextCursor: nil)
        }, isCurrent: { true })
        XCTAssertNil(retryStore.error)
        XCTAssertEqual(retryStore.cuts.map(\.id), ["retry"])
    }

    @MainActor
    func testCoverageUncoverReusesThePageAndRefreshKeepsRowsUntilReplacement() async {
        let identity = KnowledgePresentationIdentity(profileID: "fixture", lifecycleGeneration: 1, connectionID: 1)
        let range = KnowledgeObservationPresentation(record: KnowledgeObservationFixture.record())!.observation.range
        let cut = Self.syntheticCut("failed-cut", .failed, range: range)
        let store = KnowledgeCoveragePresentationStore()
        await store.load(identity: identity, request: { _ in
            KnowledgeCoveragePage(coverage: [cut], stateRevision: 1, nextCursor: "next-page")
        }, isCurrent: { true })
        store.suspend()
        await store.load(identity: identity, expectedStateRevision: 1, request: { _ in
            XCTFail("Closing an unchanged sheet must not reload coverage")
            return KnowledgeCoveragePage(coverage: [], stateRevision: 1, nextCursor: nil)
        }, isCurrent: { true })
        XCTAssertEqual(store.cuts, [cut]); XCTAssertEqual(store.nextCursor, "next-page")
        await store.load(identity: identity, expectedStateRevision: 2, request: { _ in
            await MainActor.run {
                XCTAssertEqual(store.cuts, [cut], "Keep rows while the replacement is in flight")
                XCTAssertTrue(store.loading)
                XCTAssertFalse(store.showsInitialLoading, "Do not replace retained coverage with a spinner")
            }
            return KnowledgeCoveragePage(coverage: [], stateRevision: 2, nextCursor: nil)
        }, isCurrent: { true })
        XCTAssertTrue(store.cuts.isEmpty); XCTAssertEqual(store.stateRevision, 2)
        let other = KnowledgePresentationIdentity(profileID: "other", lifecycleGeneration: 2, connectionID: 2)
        await store.load(identity: other, expectedStateRevision: 2, request: { _ in
            await MainActor.run { XCTAssertTrue(store.showsInitialLoading); XCTAssertNil(store.stateRevision) }
            return KnowledgeCoveragePage(coverage: [], stateRevision: 2, nextCursor: nil)
        }, isCurrent: { true })
    }

    @MainActor
    func testCoverageClearRequiresAGatewayThatOwnsTheMutation() async {
        var calls = 0
        let client = KnowledgeRPCClient(request: { _, _, _ in calls += 1; return .null })
        let cut = Self.syntheticCut("failed-cut", .failed, range: KnowledgeObservationPresentation(record: KnowledgeObservationFixture.record())!.observation.range)
        do {
            _ = try await client.dismissCoverage(cut, capabilities: ["knowledge.v1"])
            XCTFail("Old Gateways must not silently ignore a coverage clear")
        } catch let error as GatewayFailure { XCTAssertEqual(error.code, "unsupported") }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testObjectReaderOwnerKeepsMultichunkRepresentationsAndRetiresLateResponse() async {
        let primary = KnowledgeObjectRef(hash: String(repeating: "p", count: 64), mediaType: "text/plain", bytes: 12)
        let article = KnowledgeObjectRef(hash: String(repeating: "a", count: 64), mediaType: "text/html", bytes: 7)
        let primaryKey = KnowledgeObjectSelectionKey(recordID: "source", revisionID: "revision", reference: primary)
        let articleKey = KnowledgeObjectSelectionKey(recordID: "source", revisionID: "revision", reference: article)
        let store = KnowledgeObjectReaderStore()
        await store.load(primaryKey, offset: 0, request: { reference, offset in
            KnowledgeObjectRead(hash: reference.hash, mediaType: reference.mediaType, bytes: 6, totalBytes: 12, offset: offset, nextOffset: 6, base64: Data("first-".utf8).base64EncodedString())
        }, isCurrent: { true })
        await store.load(primaryKey, offset: 6, request: { reference, offset in
            KnowledgeObjectRead(hash: reference.hash, mediaType: reference.mediaType, bytes: 6, totalBytes: 12, offset: offset, nextOffset: nil, base64: Data("second".utf8).base64EncodedString())
        }, isCurrent: { true })
        XCTAssertEqual(String(data: store.state(for: primaryKey).bytes, encoding: .utf8), "first-second")
        await store.load(articleKey, offset: 0, request: { reference, offset in
            KnowledgeObjectRead(hash: reference.hash, mediaType: reference.mediaType, bytes: 7, totalBytes: 7, offset: offset, nextOffset: nil, base64: Data("ARTICLE".utf8).base64EncodedString())
        }, isCurrent: { true })
        XCTAssertEqual(String(data: store.state(for: primaryKey).bytes, encoding: .utf8), "")
        let stale = Task { @MainActor in
            await store.load(articleKey, offset: 0, request: { reference, offset in
                try await Task.sleep(for: .milliseconds(80))
                return KnowledgeObjectRead(hash: reference.hash, mediaType: reference.mediaType, bytes: 7, totalBytes: 7, offset: offset, nextOffset: nil, base64: Data("STALE!!".utf8).base64EncodedString())
            }, isCurrent: { true })
        }
        try? await Task.sleep(for: .milliseconds(5))
        await store.load(articleKey, offset: 0, request: { reference, offset in
            KnowledgeObjectRead(hash: reference.hash, mediaType: reference.mediaType, bytes: 7, totalBytes: 7, offset: offset, nextOffset: nil, base64: Data("FRESH!!".utf8).base64EncodedString())
        }, isCurrent: { true })
        await stale.value
        XCTAssertEqual(String(data: store.state(for: articleKey).bytes, encoding: .utf8), "FRESH!!")
        XCTAssertTrue(store.state(for: primaryKey).bytes.isEmpty, "Switching representations releases the previous bounded reader")
        XCTAssertNil(store.state(for: primaryKey).nextOffset)
    }

    @MainActor
    func testObjectReaderRejectsInconsistentEnvelopeAndRetiresLoadingOnSuspend() async {
        let reference = KnowledgeObjectRef(hash: String(repeating: "h", count: 64), mediaType: "text/plain", bytes: 6)
        let key = KnowledgeObjectSelectionKey(recordID: "source", revisionID: "revision", reference: reference)
        let store = KnowledgeObjectReaderStore()
        let request = Task { @MainActor in
            await store.load(key, offset: 0, request: { _, _ in
                try await Task.sleep(for: .milliseconds(80))
                return KnowledgeObjectRead(hash: reference.hash, mediaType: reference.mediaType, bytes: 4, totalBytes: 6, offset: 0, nextOffset: nil, base64: Data("four".utf8).base64EncodedString())
            }, isCurrent: { true })
        }
        store.suspend()
        await request.value
        XCTAssertFalse(store.state(for: key).loading)

        await store.load(key, offset: 0, request: { _, _ in
            KnowledgeObjectRead(hash: reference.hash, mediaType: reference.mediaType, bytes: 4, totalBytes: 6, offset: 0, nextOffset: nil, base64: Data("four".utf8).base64EncodedString())
        }, isCurrent: { true })
        XCTAssertEqual(store.state(for: key).error, "Retained object response is invalid.")
    }

    @MainActor
    func testLinkedRecordReaderPublishesVisibleUnavailableAndRetiresOlderCitation() async {
        let cancelledStore = KnowledgeLinkedRecordReaderStore()
        await cancelledStore.load(id: "cancelled", revisionID: nil, request: { _, _ in throw CancellationError() }, isCurrent: { true })
        XCTAssertFalse(cancelledStore.loading)
        let store = KnowledgeLinkedRecordReaderStore()
        await store.load(id: "missing", revisionID: "revision-a", request: { _, _ in nil }, isCurrent: { true })
        XCTAssertEqual(store.error, "Linked record is unavailable, excluded, or forgotten. Retry from this detail.")
        await store.load(id: "new", revisionID: "new-revision", request: { _, _ in
            KnowledgeModelsTests.syntheticRecord(id: "new", revision: "new-revision")
        }, isCurrent: { true })
        XCTAssertEqual(store.record?.id, "new")
        let staleStore = KnowledgeLinkedRecordReaderStore()
        let stale = Task { @MainActor in
            await staleStore.load(id: "old", revisionID: "old-revision", request: { _, _ in
                try await Task.sleep(for: .milliseconds(80)); return KnowledgeModelsTests.syntheticRecord(id: "old", revision: "old-revision")
            }, isCurrent: { false })
        }
        await stale.value
        XCTAssertNil(staleStore.record)
    }

    nonisolated static func syntheticRecord(id: String, revision: String) -> KnowledgeRecord {
        KnowledgeRecord(schemaVersion: 1, id: id, revisionId: revision, kind: .note, scope: .research,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            provenance: KnowledgeProvenance(actor: .user, source: nil, sessionId: nil, branchId: nil, invocationId: nil, evidence: []),
            temporal: nil, relations: [], content: .note(KnowledgeNoteContent(title: id, body: "fixture", fields: nil, role: .fact, confirmed: false, contraryEvidence: nil, freshness: .unknown, privacyScope: nil, usageConstraint: nil)))
    }

    nonisolated static func syntheticCut(_ id: String, _ disposition: KnowledgeCoverageDisposition, range: KnowledgeObservationRange) -> KnowledgeObservationCoverage {
        KnowledgeObservationCoverage(schemaVersion: 1, id: id, revisionId: "revision-\(id)", range: range, disposition: disposition, groupRevisionIds: [], recordedAt: "2026-01-01T00:00:00Z", reason: "fixture")
    }

    func testCoveragePresentationNamesAttentionAndBoundsCitations() {
        let range = KnowledgeObservationPresentation(record: KnowledgeObservationFixture.record())!.observation.range
        func summary(remaining: Int, pending: Int = 0, failed: Int = 0, unavailable: Int = 0) -> KnowledgeCoverageSummary {
            KnowledgeCoverageSummary(observedCount: 367, emptyCount: 3, excludedCount: 27,
                                     pendingCount: pending, failedCount: failed, unavailableCount: unavailable,
                                     remainingCount: remaining)
        }

        XCTAssertEqual(KnowledgeCoveragePresentationPolicy.settledLabel(summary(remaining: 6)), "397 settled")
        XCTAssertEqual(KnowledgeCoveragePresentationPolicy.attentionTitle(summary(remaining: 6)), "6 cuts need attention")
        XCTAssertEqual(KnowledgeCoveragePresentationPolicy.attentionDetail(summary(remaining: 6, failed: 2, unavailable: 4)),
                       "pending 0 · failed 2 · unavailable 4")
        XCTAssertEqual(KnowledgeCoveragePresentationPolicy.attentionTitle(summary(remaining: 1, failed: 1)), "1 cut needs attention")
        XCTAssertEqual(KnowledgeCoveragePresentationPolicy.attentionTitle(summary(remaining: 0)), "No cuts need attention")
        XCTAssertEqual(KnowledgeCoveragePresentationPolicy.settledDetail(summary(remaining: 0)),
                       "Observed 367 · Empty 3 · Excluded 27", "The overview always reports the settled counts")
        XCTAssertNil(KnowledgeCoveragePresentationPolicy.listProgress(summary(remaining: 2), loaded: 2))
        XCTAssertEqual(KnowledgeCoveragePresentationPolicy.listProgress(summary(remaining: 6), loaded: 2),
                       "Showing 2 of 6 cuts needing attention.", "A partial list says so instead of implying completeness")

        XCTAssertEqual(KnowledgeCoveragePresentationPolicy.attentionDispositions, [.pending, .failed, .unavailable],
                       "The container asks the Gateway for only the cuts it lists")

        let citation = KnowledgeCoveragePresentationPolicy.citation(range)
        XCTAssertEqual(citation, "fixture-…–fixture-… · session fixture-…")
        XCTAssertLessThan(citation.count, 48, "A citation cannot dominate the row beside its actions")
        XCTAssertEqual(KnowledgeCoveragePresentationPolicy.short("bd1ff330"), "bd1ff330")
        XCTAssertEqual(KnowledgeCoveragePresentationPolicy.title(.unavailable), "Observation unavailable")
    }

    func testKnowledgeLibrarySectionsKeepRetainedSourcesPrimaryAndArchiveOptIn() {
        XCTAssertEqual(KnowledgeDashboardArea.allCases.map(\.title), ["Chronicle", "Library"])
        XCTAssertEqual(KnowledgeDashboardSection.allCases.map(\.title), ["Chronicle", "Sources", "Syntheses", "Intake & archive"])
        XCTAssertFalse(KnowledgeDashboardSection.sources.includesPendingOrArchived)
        XCTAssertFalse(KnowledgeDashboardSection.syntheses.includesPendingOrArchived)
        XCTAssertTrue(KnowledgeDashboardSection.intakeArchive.includesPendingOrArchived)
        XCTAssertEqual(KnowledgeDashboardSection.syntheses.kind, .note)
    }

    func testFilteredPagesKeepLoadMoreReachableAndFindLaterSynthesis() {
        let manual = Self.syntheticRecord(id: "manual", revision: "r-manual")
        let synthesis = KnowledgeRecord(schemaVersion: manual.schemaVersion, id: "synthesis", revisionId: "r-synthesis", kind: .note, scope: .research,
                                        createdAt: manual.createdAt, updatedAt: manual.updatedAt, provenance: manual.provenance, temporal: nil, relations: [],
                                        content: .note(KnowledgeNoteContent(title: "Synthesis", body: "bounded", fields: nil, role: .synthesis, confirmed: false, contraryEvidence: nil, freshness: .unknown, privacyScope: nil, usageConstraint: nil)))
        XCTAssertTrue(KnowledgeCatalogPagePolicy.visibleRecords([manual], in: .syntheses).isEmpty)
        XCTAssertEqual(KnowledgeCatalogPagePolicy.visibleRecords([synthesis], in: .syntheses).map(\.id), ["synthesis"])
        XCTAssertTrue(KnowledgeCatalogPagePolicy.offersContinuation(nextCursor: "page-2", loadingMore: false), "An empty filtered page must still expose continuation")
        XCTAssertFalse(KnowledgeCatalogPagePolicy.offersContinuation(nextCursor: nil, loadingMore: false))
    }

    func testSectionPageFenceRejectsLateResponseAfterLibrarySwitch() {
        let chronicle = KnowledgeCatalogRequestKey(section: .chronicle, kind: .observation, scope: nil, search: "")
        let sources = KnowledgeCatalogRequestKey(section: .sources, kind: .source, scope: nil, search: "")
        XCTAssertFalse(KnowledgeCatalogRequestFence.accepts(chronicle, current: sources))
        XCTAssertTrue(KnowledgeCatalogRequestFence.accepts(sources, current: sources))
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
        XCTAssertTrue(handoff.contains("Qualifications: none retained"))
        XCTAssertNil(KnowledgeDraftHandoffPolicy.text(for: record, identity: KnowledgePresentationIdentity(profileID: nil, lifecycleGeneration: nil, connectionID: nil)))
    }

    func testImportPresentationDoesNotClaimWholeCorpusAfterOneBatch() {
        XCTAssertEqual(KnowledgeImportPresentationPolicy.corpusProgress(planned: 120, selected: 50, offset: 0), "50 of 120")
        let plan = KnowledgeImportPlan(operation: "dry-run", source: "synthetic", planHash: "plan", planned: 120, selected: 50, imported: 0, resumed: 0, skipped: 0, failed: 0, completed: false, progress: KnowledgeImportProgress(completed: 0, remaining: 50, total: 50), mappings: [], warnings: [])
        let result = KnowledgeImportResult(operation: "run", source: "synthetic", planHash: "plan", planned: 120, selected: 50, imported: 50, resumed: 0, skipped: 0, failed: 0, completed: false, progress: KnowledgeImportProgress(completed: 50, remaining: 70, total: 120), mappings: [], warnings: [])
        XCTAssertEqual(KnowledgeImportPresentationPolicy.completionMessage(plan: plan, result: result, offset: 0), "Batch complete (50 of 120); continuing with 70 remaining.")
        let failed = KnowledgeImportResult(operation: "run", source: "synthetic", planHash: "plan", planned: 120, selected: 50, imported: 49, resumed: 0, skipped: 0, failed: 1, completed: false, progress: KnowledgeImportProgress(completed: 49, remaining: 1, total: 50), mappings: [], warnings: [])
        XCTAssertTrue(KnowledgeImportPresentationPolicy.completionMessage(plan: plan, result: failed, offset: 0).contains("incomplete"))

        let widePlan = KnowledgeImportPlan(operation: "dry-run", source: "personal-os", planHash: "wide-plan", planned: 53, selected: 50, imported: 0, resumed: 0, skipped: 0, failed: 0, completed: true, progress: KnowledgeImportProgress(completed: 0, remaining: 53, total: 53), mappings: [], warnings: [])
        let partial = KnowledgeImportResult(operation: "run", source: "personal-os", planHash: "wide-plan", planned: 53, selected: 53, imported: 49, resumed: 0, skipped: 0, failed: 1, completed: false, progress: KnowledgeImportProgress(completed: 49, remaining: 4, total: 53), mappings: [], warnings: [])
        XCTAssertTrue(KnowledgeImportPresentationPolicy.completionMessage(plan: widePlan, result: partial, offset: 0).contains("retry"))
        let resumed = KnowledgeImportResult(operation: "run", source: "personal-os", planHash: "wide-plan", planned: 53, selected: 53, imported: 4, resumed: 49, skipped: 0, failed: 0, completed: true, progress: KnowledgeImportProgress(completed: 53, remaining: 0, total: 53), mappings: [], warnings: [])
        XCTAssertEqual(KnowledgeImportPresentationPolicy.completionMessage(plan: widePlan, result: resumed, offset: 0), "Import complete (4 imported).")
    }

    func testSourcePresentationSeparatesSafeLinksCoverageAndAdmission() throws {
        XCTAssertEqual(KnowledgeSourcePresentationPolicy.domain("https://Example.com/path"), "example.com")
        XCTAssertNil(KnowledgeSourcePresentationPolicy.safeURL("file:///private/fixture"))
        XCTAssertNil(KnowledgeSourcePresentationPolicy.safeURL("javascript:alert(1)"))
        XCTAssertNil(KnowledgeSourcePresentationPolicy.safeURL("https://user:password@example.com/article"))
        let objectOnly = KnowledgeSourceContent(title: "Binary", uri: "https://example.com/file", text: nil, object: KnowledgeObjectRef(hash: String(repeating: "a", count: 64), mediaType: "application/octet-stream", bytes: 2), mediaType: "application/octet-stream", captureDisposition: .complete, annotations: nil, sourcePublishedAt: nil, capturedAt: "2026-01-01T00:00:00Z", origin: "manual", origins: nil, identity: nil, assessment: nil)
        XCTAssertEqual(KnowledgeSourcePresentationPolicy.coverageTitle(objectOnly), "Captured object retained; extracted text unavailable")
        let source = KnowledgeSourceContent(title: "Partial source", uri: "https://example.com/article", text: nil, object: nil,
                                            representations: nil, mediaType: "text/html", captureDisposition: .partial,
                                            annotations: nil, sourcePublishedAt: nil, capturedAt: "2026-01-01T00:00:00Z", origin: "connector",
                                            origins: nil, identity: nil, assessment: nil)
        XCTAssertEqual(KnowledgeSourcePresentationPolicy.coverageTitle(source.captureDisposition), "Partial capture")
        XCTAssertTrue(KnowledgeSourcePresentationPolicy.coverageDetail(source).contains("Only part"))
        XCTAssertEqual(KnowledgeSourcePresentationPolicy.coverageSummary(source), "Partial capture · example.com")
        let pending = KnowledgeSourceAdmissionState(status: .pending, reason: "Needs review", decidedAt: "2026-01-01T00:00:00Z", profileVersion: nil, rubricVersion: nil)
        XCTAssertEqual(KnowledgeSourcePresentationPolicy.admissionLabel(pending), "Pending intake")
        XCTAssertNil(KnowledgeSourcePresentationPolicy.summary(source))
        XCTAssertEqual(KnowledgeSourcePresentationPolicy.sourceType(source), "Web page")
        XCTAssertEqual(KnowledgeSourcePresentationPolicy.thumbnailLetters(source), "EC")
    }

    func testSourceWireShapeDecodesCaptureReasonAndAssessmentMetadataWithoutInventingConfidence() throws {
        let data = Data(#"{"schemaVersion":1,"id":"source","revisionId":"r1","kind":"source","scope":"research","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","provenance":{"actor":"connector","evidence":[]},"relations":[],"content":{"title":"Metadata","uri":"https://example.com","captureDisposition":"metadata-only","captureReason":"Provider returned metadata without readable text","capturedAt":"2026-01-01T00:00:00Z","assessment":{"summary":"Bounded review","evidenceQuality":"unknown","freshness":"unknown","generatedAt":"2026-01-01T00:00:00Z","coverage":"sampled","classification":"reference","inputDigest":"digest","usage":{"inputTokens":12,"outputTokens":4,"estimatedCostCents":0,"pricing":"fixture"}}}}"#.utf8)
        let record = try JSONDecoder().decode(KnowledgeRecord.self, from: data)
        guard case .source(let source) = record.content else { return XCTFail("Expected source") }
        XCTAssertEqual(source.captureDisposition, .metadataOnly)
        XCTAssertEqual(source.captureReason, "Provider returned metadata without readable text")
        XCTAssertEqual(source.assessment?.coverage, "sampled")
        XCTAssertEqual(source.assessment?.classification, "reference")
        XCTAssertEqual(source.assessment?.usage?.inputTokens, 12)
        XCTAssertEqual(KnowledgeSourcePresentationPolicy.summary(source), "Bounded review")
        XCTAssertEqual(record.summary, "Bounded review")
        XCTAssertNil(source.assessment?.confidence, "Missing confidence must remain missing")
    }

    func testSourceAndNoteUseTheCommonDiscriminatedContentShape() throws {
        let source = KnowledgeRecord(
            schemaVersion: 1, id: "source-1", revisionId: "revision-1", kind: .source, scope: .research,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            provenance: KnowledgeProvenance(actor: .user, source: nil, sessionId: nil, branchId: nil, invocationId: nil, evidence: []), temporal: nil, relations: [],
            content: .source(KnowledgeSourceContent(title: "A link", uri: "https://example.com", text: nil, object: nil, representations: [KnowledgeSourceRepresentation(kind: .linkedArticle, object: KnowledgeObjectRef(hash: String(repeating: "d", count: 64), mediaType: "text/html", bytes: 4), mediaType: "text/html")], mediaType: nil, captureDisposition: .referenceOnly, annotations: nil, sourcePublishedAt: nil, capturedAt: "2026-01-01T00:00:00Z", origin: "manual", origins: [KnowledgeSourceOrigin(kind: .manual, capturedAt: "2026-01-01T00:00:00Z", annotation: "saved", uri: "https://example.com", identity: nil)], identity: KnowledgeSourceIdentity(provider: "raindrop", accountId: "account", itemId: "item"), assessment: KnowledgeSourceAssessment(summary: "A useful source", contribution: nil, whyItMatters: nil, evidenceQuality: .high, freshness: .current, possibleUse: "cite it", generatedAt: "2026-01-01T00:00:00Z", model: "model")))
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
        XCTAssertEqual(sourceContent.representations?.first?.kind, .linkedArticle)
        XCTAssertEqual(sourceContent.assessment?.evidenceQuality, .high)
        XCTAssertEqual(sourceContent.origins?.first?.annotation, "saved")
    }

    func testSourceCorrectionPreservesCapturedRepresentationAndAttributesNewRevisionToUser() throws {
        let source = KnowledgeRecord(
            schemaVersion: 1, id: "source-1", revisionId: "revision-4", kind: .source, scope: .research,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            provenance: KnowledgeProvenance(actor: .connector, source: "raindrop", sessionId: nil, branchId: nil, invocationId: "invoke-1", evidence: []), temporal: nil, relations: [],
            content: .source(KnowledgeSourceContent(title: "Captured", uri: "https://example.com", text: "original readable text", object: KnowledgeObjectRef(hash: String(repeating: "c", count: 64), mediaType: "text/plain", bytes: 21), representations: [KnowledgeSourceRepresentation(kind: .providerAPI, object: KnowledgeObjectRef(hash: String(repeating: "d", count: 64), mediaType: "application/json", bytes: 8), mediaType: "application/json"), KnowledgeSourceRepresentation(kind: .linkedArticle, object: KnowledgeObjectRef(hash: String(repeating: "e", count: 64), mediaType: "text/html", bytes: 12), mediaType: "text/html")], mediaType: "text/plain", captureDisposition: .complete, annotations: nil, sourcePublishedAt: nil, capturedAt: "2026-01-01T00:00:00Z", origin: "connector", origins: nil, identity: nil, assessment: nil))
        )
        guard case .source(let corrected) = KnowledgeCorrectionPolicy.content(for: source, replacementText: "the corrected interpretation") else { return XCTFail("Expected source correction") }
        XCTAssertEqual(corrected.text, "original readable text")
        XCTAssertEqual(corrected.object?.hash, String(repeating: "c", count: 64))
        XCTAssertEqual(corrected.representations?.map(\.kind), [.providerAPI, .linkedArticle])
        XCTAssertEqual(corrected.annotations?.last?.text, "User correction: the corrected interpretation")
        XCTAssertEqual(KnowledgeCorrectionPolicy.provenance(for: source).actor, .user)
        XCTAssertEqual(KnowledgeCorrectionPolicy.provenance(for: source).source, "ios-correction")
        XCTAssertEqual(KnowledgeCorrectionPolicy.provenance(for: source).evidence.last?.revisionId, "revision-4")
    }

    func testKnowledgeHandoffCarriesBoundedQualificationsAndEvidence() {
        let record = KnowledgeRecord(
            schemaVersion: 1, id: "qualified-note", revisionId: "revision-2", kind: .note, scope: .research,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            provenance: KnowledgeProvenance(actor: .agent, source: "import", sessionId: nil, branchId: nil, invocationId: nil, evidence: [KnowledgeEvidenceRef(recordId: "source-1", revisionId: "source-r1", sessionEntry: nil, objectHash: nil, locator: "line 4")]), temporal: nil, relations: [],
            content: .note(KnowledgeNoteContent(title: "Qualified", body: "candidate", fields: [KnowledgeNoteFieldQualification(field: "status", value: .string("historical"), subject: nil, evidence: [KnowledgeEvidenceRef(recordId: "source-1", revisionId: "source-r1", sessionEntry: nil, objectHash: nil, locator: "line 4")], certainty: .historical, validFrom: "2020-01-01", validTo: nil)], role: .fact, confirmed: false, contraryEvidence: nil, freshness: .aging, privacyScope: "private", usageConstraint: nil))
        )
        let handoff = KnowledgeDraftHandoffPolicy.text(for: record, identity: KnowledgePresentationIdentity(profileID: "gateway-a", lifecycleGeneration: 1, connectionID: 1))!
        XCTAssertTrue(handoff.contains("status=historical [historical]"))
        XCTAssertTrue(handoff.contains("evidence=source-1"))
        XCTAssertTrue(handoff.contains("Record ID: qualified-note · Revision: revision-2"))
    }
}
