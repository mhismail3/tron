import Foundation
import Testing
@testable import TronMobile

/// Behavioral coverage for `GitActionRunner` — the shared state machine
/// every git sub-sheet uses for its primary action. Tests pin every
/// state transition: the success path (auto-dismiss), the error path
/// (no auto-dismiss), the stays-open path (clean success false), the
/// re-entrancy guard, and the result-reset between runs.
@Suite("GitActionRunner state machine")
@MainActor
struct GitActionRunnerTests {

    private struct StubResult: GitActionResult {
        let isCleanSuccess: Bool
    }

    private struct StubError: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    // MARK: - Success path

    @Test("clean success populates result and fires dismiss")
    func cleanSuccessAutoDismisses() async {
        let runner = GitActionRunner<StubResult>()
        nonisolated(unsafe) var dismissed = 0

        await runner.run(
            action: .commit,
            dismiss: { dismissed += 1 },
            perform: { StubResult(isCleanSuccess: true) }
        )

        #expect(runner.result?.isCleanSuccess == true)
        #expect(runner.errorMessage == nil)
        #expect(runner.isDismissingAfterSuccess == true)
        #expect(runner.isEnabled == false, "result on screen blocks re-fire")
        #expect(dismissed == 1)
    }

    // MARK: - Stays-open path (clean success false)

    @Test("non-clean result populates result without dismissing")
    func nonCleanResultStaysOpen() async {
        let runner = GitActionRunner<StubResult>()
        nonisolated(unsafe) var dismissed = 0

        await runner.run(
            action: .push,
            dismiss: { dismissed += 1 },
            perform: { StubResult(isCleanSuccess: false) }
        )

        #expect(runner.result?.isCleanSuccess == false)
        #expect(runner.isDismissingAfterSuccess == false)
        #expect(dismissed == 0)
    }

    // MARK: - Error path

    @Test("thrown error populates errorMessage; no result; no dismiss")
    func errorPathDoesNotAutoDismiss() async {
        let runner = GitActionRunner<StubResult>()
        nonisolated(unsafe) var dismissed = 0

        await runner.run(
            action: .merge,
            dismiss: { dismissed += 1 },
            perform: { throw StubError() }
        )

        #expect(runner.result == nil)
        #expect(runner.errorMessage?.contains("Merge failed") == true)
        #expect(runner.errorMessage?.contains("boom") == true)
        #expect(runner.isDismissingAfterSuccess == false)
        #expect(dismissed == 0)
    }

    // MARK: - Result reset between runs

    @Test("result is cleared at the start of each run()")
    func resultClearedBetweenRuns() async {
        let runner = GitActionRunner<StubResult>()

        // First run: stays-open
        await runner.run(
            action: .sync,
            dismiss: {},
            perform: { StubResult(isCleanSuccess: false) }
        )
        #expect(runner.result?.isCleanSuccess == false)

        // Second run: should clear result before perform begins
        await runner.run(
            action: .sync,
            dismiss: {},
            perform: {
                #expect(runner.result == nil, "result must be nil while perform runs")
                return StubResult(isCleanSuccess: false)
            }
        )
    }

    // MARK: - Error → success cycle

    @Test("error then success replaces error and dismisses")
    func errorThenSuccess() async {
        let runner = GitActionRunner<StubResult>()
        nonisolated(unsafe) var dismissed = 0

        // First: throw
        await runner.run(
            action: .push,
            dismiss: { dismissed += 1 },
            perform: { throw StubError() }
        )
        #expect(runner.errorMessage?.isEmpty == false)
        #expect(dismissed == 0)

        // Second: clean success
        await runner.run(
            action: .push,
            dismiss: { dismissed += 1 },
            perform: { StubResult(isCleanSuccess: true) }
        )
        #expect(runner.result?.isCleanSuccess == true)
        #expect(dismissed == 1)
        // errorMessage from prior run is intentionally NOT cleared by
        // run() — the alert binding takes care of dismissing it. Sub-
        // sheets bind `$runner.errorMessage` to `tronErrorAlert(...)`.
    }

    // MARK: - isEnabled invariants

    @Test("isEnabled reflects every blocking state")
    func isEnabledMatrix() {
        let runner = GitActionRunner<StubResult>()
        #expect(runner.isEnabled == true)

        runner.isRunning = true
        #expect(runner.isEnabled == false, "running blocks")
        runner.isRunning = false

        runner.result = StubResult(isCleanSuccess: false)
        #expect(runner.isEnabled == false, "result on screen blocks")
        runner.result = nil

        runner.isDismissingAfterSuccess = true
        #expect(runner.isEnabled == false, "scheduled dismiss blocks")
    }
}

// MARK: - GitActionResult conformances

/// JSON round-trip the wire format so we exercise the actual decoder
/// path. The structs use `Decodable` only (no memberwise init).
private func decode<T: Decodable>(_ json: [String: Any]) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(T.self, from: data)
}

@Suite("GitActionResult conformances")
struct GitActionResultConformanceTests {

    @Test("WorktreeCommitResult: hash present → clean")
    func commitWithHashIsClean() throws {
        let r: WorktreeCommitResult = try decode([
            "commitHash": "abc1234",
            "filesChanged": ["foo.txt"],
            "insertions": 1,
            "deletions": 0,
        ])
        #expect(r.isCleanSuccess == true)
    }

    @Test("WorktreeCommitResult: nil hash → stays open")
    func commitNoHashStaysOpen() throws {
        let r: WorktreeCommitResult = try decode([:])
        #expect(r.isCleanSuccess == false)
    }

    @Test("GitPushResult: real push → clean")
    func pushRealIsClean() throws {
        let r: GitPushResult = try decode([
            "branch": "feature/x",
            "remote": "origin",
            "setUpstream": true,
            "dryRun": false,
        ])
        #expect(r.isCleanSuccess == true)
    }

    @Test("GitPushResult: dry run → stays open")
    func pushDryRunStaysOpen() throws {
        let r: GitPushResult = try decode([
            "branch": "feature/x",
            "remote": "origin",
            "setUpstream": true,
            "dryRun": true,
        ])
        #expect(r.isCleanSuccess == false)
    }

    @Test("GitSyncOutcome: upToDate / fastForwarded → clean; previews / blocked → stays open")
    func syncOutcomeMatrix() {
        #expect(GitSyncOutcome.upToDate(head: "abc").isCleanSuccess == true)
        #expect(
            GitSyncOutcome.fastForwarded(oldHead: "a", newHead: "b", advancedBy: 1)
                .isCleanSuccess == true
        )
        #expect(
            GitSyncOutcome.dryRunPreview(head: "a", remoteHead: "b", wouldAdvanceBy: 1)
                .isCleanSuccess == false
        )
        #expect(
            GitSyncOutcome.blocked(reason: .dirtyWorkingTree).isCleanSuccess == false
        )
    }

    @Test("WorktreeRebaseOnMainResult: success → clean; conflicts/noOp → stays open")
    func rebaseOutcomeMatrix() throws {
        let success: WorktreeRebaseOnMainResult = try decode([
            "type": "success",
            "oldBaseCommit": "old",
            "newBaseCommit": "new",
            "mainCommitsIncorporated": 1,
            "strategy": "rebase",
            "hadAutoStash": false,
        ])
        let conflicts: WorktreeRebaseOnMainResult = try decode([
            "type": "conflicts",
            "count": 1,
        ])
        let noOp: WorktreeRebaseOnMainResult = try decode([
            "type": "noOp",
            "ahead": 0,
        ])
        #expect(success.isCleanSuccess == true)
        #expect(conflicts.isCleanSuccess == false)
        #expect(noOp.isCleanSuccess == false)
    }

    @Test("WorktreeFinalizeSessionResult: conflicts true → stays open; otherwise clean")
    func finalizeOutcomeMatrix() throws {
        let clean: WorktreeFinalizeSessionResult = try decode([
            "mergeCommit": "abc",
            "newBranch": "feature/x-2",
        ])
        let withConflicts: WorktreeFinalizeSessionResult = try decode([
            "conflicts": true,
            "error": "merge conflicts",
        ])
        #expect(clean.isCleanSuccess == true)
        #expect(withConflicts.isCleanSuccess == false)
    }
}
