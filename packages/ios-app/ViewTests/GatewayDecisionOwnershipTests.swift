import XCTest
import TronMobileCore
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
        let model = ModelSummary(provider: "fixture", id: "large", name: "Large", virtual: false, reasoning: false, input: ["text"],
                                 contextWindow: 1_000_000, contextWindowLimits: limits, maxTokens: 64_000, available: true)
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
}
