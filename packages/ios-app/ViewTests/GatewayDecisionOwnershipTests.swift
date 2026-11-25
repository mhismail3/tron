import XCTest
@testable import TronMobileCore
@testable import TronMobile

final class GatewayDecisionOwnershipTests: XCTestCase {
    private let observed = "2026-11-24T00:00:00.000Z"

    private func activity(_ id: String, visibility: PresentedProcessVisibility, lifecycle: PresentedProcessLifecycle) -> PresentedProcessActivity {
        PresentedProcessActivity(processId: id, kind: .subagent, executionMode: .asynchronous, source: .delegatedAgent,
                                 lifecycle: lifecycle, visibility: visibility, title: id)
    }

    func testTheAppInstallsTheGatewaysDecidedProcessOverviewAndRecency() {
        var snapshot = SnapshotCacheFixtureGateway.snapshot()
        let running = activity("running", visibility: .active, lifecycle: PresentedProcessLifecycle(state: .running, sequence: 1, observedAt: observed))
        let recent = activity("recent", visibility: .recent, lifecycle: PresentedProcessLifecycle(
            state: .completed, sequence: 2, observedAt: observed, terminalAt: observed, recentUntil: "2026-11-24T00:01:00.000Z"))
        snapshot.processActivities = [running, recent]
        snapshot.processOverview = PresentedProcessOverview(revision: 1, asOf: observed, activeCount: 3, recentCount: 1, problemCount: 0,
                                                            visibility: .active, nearestExpiry: "2026-11-24T00:01:00.000Z")
        XCTAssertTrue(SessionProcessAdmissionPolicy.admitsSnapshotFacts(snapshot), "The app installs the Gateway's counts and expiry as sent")
        snapshot.processOverview = PresentedProcessOverview(revision: 1, asOf: observed, activeCount: -1, recentCount: 1, problemCount: 0,
                                                            visibility: .active)
        XCTAssertFalse(SessionProcessAdmissionPolicy.admitsSnapshotFacts(snapshot), "Bounds admission of untrusted input stays")
    }

    private func extensionActivity(_ id: String, updatedAt: String, lifecycle: ExtensionActivityLifecycle,
                                   status: ExtensionRunActivity.Status = .completed, title: String? = nil,
                                   children: [ExtensionRunChild] = []) -> ExtensionRunActivity {
        ExtensionRunActivity(id: id, toolCallId: id, source: ExtensionToolOrigin(source: "project"), title: title ?? id,
                             status: status, startedAt: observed, updatedAt: updatedAt, children: children, lifecycle: lifecycle)
    }

    func testTheAppInstallsTheGatewaysDecidedExtensionLifecycleRecencyAndOrder() {
        let decided = ExtensionActivityLifecycle(state: .completed, sequence: 2, observedAt: observed, terminalAt: observed,
                                                 recentUntil: "2026-11-23T23:59:00.000Z", visibility: .unknown)
        let unknownChild = ExtensionRunChild(id: "child", label: "child", status: .running, lifecycle: .unknown)
        let sent = extensionActivity("decided", updatedAt: observed, lifecycle: decided, status: .running, children: [unknownChild])
        XCTAssertEqual(ExtensionActivityAdmissionPolicy.admitted([sent]), [sent], "The app installs the Gateway's lifecycle, recency and child state as sent")
        XCTAssertFalse(ExtensionActivityAdmissionPolicy.admits(extensionActivity("oversized", updatedAt: observed, lifecycle: decided,
                                                                                 title: String(repeating: "x", count: 513))),
                       "Bounds admission of untrusted input stays")

        let gatewayOrder = (0..<33).map { index in
            extensionActivity("activity-\(index)", updatedAt: String(format: "2026-11-24T00:00:%02d.000Z", 59 - index),
                              lifecycle: ExtensionActivityLifecycle(state: .completed, sequence: 1, observedAt: observed,
                                                                    terminalAt: observed, recentUntil: index.isMultiple(of: 2) ? "2026-11-24T00:15:00.000Z" : nil,
                                                                    visibility: index.isMultiple(of: 2) ? .recent : .historical,
                                                                    remainingMs: index.isMultiple(of: 2) ? 60_000 : nil))
        }
        XCTAssertEqual(ExtensionActivityAdmissionPolicy.admitted(gatewayOrder).map(\.id), gatewayOrder.prefix(32).map(\.id),
                       "Past the cap the app keeps the Gateway's order")
    }

    func testLiveOutputRendersAsTheGatewaySentIt() {
        let tool = { (output: String, truncated: Bool?) in
            ToolExecutionState(toolCallId: "call", toolName: "bash", status: .running, arguments: .object([:]), partialResult: nil,
                               result: nil, output: output, outputTruncated: truncated, isError: false, startedAt: self.observed, updatedAt: self.observed)
        }
        let sent = "… earlier live output truncated by gateway …\n" + String(repeating: "x", count: 120 * 1_024)
        let merged = ToolExecutionStatePolicy.mergingLiveEvidence(from: tool("before", nil), into: tool(sent, true))
        XCTAssertEqual(merged.output, sent)
        XCTAssertEqual(merged.outputTruncated, true)
    }

    func testTheModelCatalogShowsTheGatewaysContextWindowLimits() throws {
        let limits = ContextWindowLimits(minimum: 4_096, maximum: 200_000_000, default: 1_000_000, longContextThreshold: 200_000)
        let model = ModelSummary(provider: "fixture", providerName: "Fixture", id: "large", name: "Large", latest: false, virtual: false, reasoning: false, input: ["text"],
                                 contextWindow: 1_000_000, contextWindowLimits: limits, maxTokens: 64_000, available: true)
        var snapshot = SnapshotCacheFixtureGateway.snapshot()
        snapshot.model = ModelRef(provider: "fixture", id: "large")
        snapshot.contextWindowPolicy = ContextWindowPolicy(model: ModelRef(provider: "fixture", id: "large"), minimum: 4_096,
                                                           maximum: 200_000_000, default: 1_000_000, effective: 150_000_000,
                                                           override: nil, source: "model", warning: nil)
        XCTAssertTrue(SessionSnapshotTranscriptAdmissionPolicy.admit(snapshot), "A session snapshot shows the Gateway's limits as sent")
        var catalog = ModelCatalogAccumulator()
        try catalog.append([model], hasNextPage: false)
        XCTAssertEqual(catalog.models.first?.contextWindowLimits, limits)
    }

    func testSnapshotEventsInstallInOrderAndResynchronizeOnGapsAndRuntimeChanges() {
        var current = SnapshotCacheFixtureGateway.snapshot()
        current.revision = 4
        current.eventSequence = 10
        let next = { (sequence: Int, revision: Int, generation: String) -> SessionSnapshot in
            var value = current
            value.eventSequence = sequence
            value.revision = revision
            value.runtimeGeneration = generation
            return value
        }
        let id = current.sessionId
        let evaluate = { (authority: Bool, sessionID: String?, incoming: SessionSnapshot) in
            SessionSnapshotEventAdmission.evaluate(eventSessionID: sessionID, hasLiveAuthority: authority, current: current, incoming: incoming)
        }
        XCTAssertEqual(evaluate(true, id, next(11, 5, current.runtimeGeneration)), .install)
        XCTAssertEqual(evaluate(true, id, next(10, 5, current.runtimeGeneration)), .ignore)
        XCTAssertEqual(evaluate(true, id, next(13, 5, current.runtimeGeneration)), .resynchronize(id))
        XCTAssertEqual(evaluate(true, id, next(11, 3, current.runtimeGeneration)), .resynchronize(id))
        XCTAssertEqual(evaluate(true, id, next(11, 5, "restarted")), .resynchronize(id))
        XCTAssertEqual(evaluate(true, "other", next(11, 5, current.runtimeGeneration)), .resynchronize("other"))
        XCTAssertEqual(evaluate(false, id, next(11, 5, current.runtimeGeneration)), .ignore)

        XCTAssertEqual(SessionRebaselineAdmission.evaluate(current: current, incoming: next(10, 4, current.runtimeGeneration)), .ignore)
        XCTAssertEqual(SessionRebaselineAdmission.evaluate(current: current, incoming: next(15, 6, current.runtimeGeneration)), .install)
        XCTAssertEqual(SessionRebaselineAdmission.evaluate(current: current, incoming: next(15, 3, current.runtimeGeneration)), .resynchronize)
        XCTAssertEqual(SessionRebaselineAdmission.evaluate(current: current, incoming: next(1, 1, "restarted")), .install)
    }

    func testDisplayURLsAdmitTheGatewaysCanonicalHostsAndRefuseRawFormsItWouldBlock() {
        for url in ["https://mooses-macbook-server.tail3b6e78.ts.net:8443/", "https://one.two.example.com/", "https://a.b.c.d/",
                    "https://8.8.8.8/", "https://1.2.0.3/", "https://[2606:4700::1111]/", "https://example.com./"] {
            XCTAssertTrue(DisplayRemoteURLPolicy.admits(url), url)
        }
        for url in ["https://127.1/", "https://012.0.0.1/", "https://0x7f.0.0.1/", "https://08.8.8.8/", "https://1.2.3/",
                    "https://4294967295/", "https://example.123/", "https://a.b.c.1/", "https://1.2.3.4.5/",
                    "https://10.0.0.1/", "https://127.0.0.1/", "https://192.168.1.1/", "https://100.64.0.1/", "https://203.0.113.1/",
                    "https://[2001:0db8::1]/", "https://[2001:db8::1]/", "https://[::1]/", "https://[::ffff:8.8.8.8]/", "https://[fe80::1]/", "https://[+2001::1]/",
                    "https://[2400:cb00::1%25x]/", "https://[2001:::1]/", "https://[2001::1::2]/",
                    "https://[2001:1:2:3:4:5:6:7::]/", "https://[2001:2:3:4:5:6:7::8]/", "https://[2001:1:2:3:4:5:6::7]/",
                    "https://[2001:1:2:3:4::5:6:7:8]/", "https://[2001:1:2:3:4:5:6:7:8::]/",
                    "https://@example.com/", "https://user@example.com/", "https://example.com/?q", "https://localhost/"] {
            XCTAssertFalse(DisplayRemoteURLPolicy.admits(url), url)
        }
    }

    func testExtensionLifecycleIntegerProjectionFailsAsAnInvalidResponse() throws {
        let method = "fixture.extensionLifecycle"
        let valid: [String: JSONValue] = ["version": .number(1), "state": .string("running"), "attention": .string("none"),
                                          "sequence": .number(1), "observedAt": .string(observed), "remainingMs": .number(5)]
        let decoded = try GatewayResponseDecoding.decode(.object(valid), as: ExtensionActivityLifecycle.self, method: method)
        XCTAssertEqual(decoded.sequence, 1)
        XCTAssertEqual(decoded.remainingMs, 5)
        for field in ["sequence", "remainingMs"] {
            for invalid in [0.5, 1e30] {
                var malformed = valid
                malformed[field] = .number(invalid)
                XCTAssertThrowsError(try GatewayResponseDecoding.decode(.object(malformed), as: ExtensionActivityLifecycle.self, method: method)) { error in
                    let failure = error as? GatewayFailure
                    XCTAssertEqual(failure?.code, "invalid_response", "\(field)=\(invalid) escaped as \(error)")
                    XCTAssertEqual(failure?.details?.objectValue?["method"]?.stringValue, method)
                    XCTAssertEqual(failure?.details?.objectValue?["category"]?.stringValue, "invalid_data")
                }
            }
        }
    }
}
