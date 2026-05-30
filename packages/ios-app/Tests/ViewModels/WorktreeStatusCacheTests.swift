import XCTest
@testable import TronMobile

@MainActor
final class WorktreeStatusCacheTests: XCTestCase {

    private var mock: MockWorktreeClient!
    private var cache: WorktreeStatusCache!

    override func setUp() async throws {
        mock = MockWorktreeClient()
        let client = mock!
        cache = WorktreeStatusCache(fetch: { id in
            try await client.getStatus(sessionId: id)
        })
    }

    override func tearDown() async throws {
        cache = nil
        mock = nil
    }

    // MARK: - Core fetch / cache

    // T1
    func test_readEmpty_returnsNil_withoutFetching() {
        XCTAssertNil(cache.status(for: "x"))
        XCTAssertEqual(mock.getStatusCallCount, 0)
    }

    // T2
    func test_ensureLoaded_storesResultFromEngineProtocol() async {
        mock.getStatusResultBySession["x"] = .fixture()

        await cache.ensureLoaded(sessionId: "x")

        XCTAssertEqual(mock.getStatusCallCount, 1)
        XCTAssertEqual(cache.status(for: "x")?.worktree?.branch, "session/alpha")
    }

    // T3 — cache hit
    func test_secondEnsureLoaded_doesNotCallEngineProtocol() async {
        mock.getStatusResultBySession["x"] = .fixture()
        await cache.ensureLoaded(sessionId: "x")
        await cache.ensureLoaded(sessionId: "x")
        XCTAssertEqual(mock.getStatusCallCount, 1)
    }

    // T4 — concurrent dedupe (same id → single engine protocol)
    func test_concurrentEnsureLoaded_dedupesSameSession() async {
        mock.getStatusDelay = 40_000_000  // 40 ms
        mock.getStatusResultBySession["x"] = .fixture()

        let cache = self.cache!
        async let a: Void = cache.ensureLoaded(sessionId: "x")
        async let b: Void = cache.ensureLoaded(sessionId: "x")
        async let c: Void = cache.ensureLoaded(sessionId: "x")
        _ = await (a, b, c)

        XCTAssertEqual(mock.getStatusCallCount, 1)
        XCTAssertNotNil(cache.status(for: "x"))
    }

    // T5 — different sessions fetch independently
    func test_concurrentEnsureLoaded_differentSessions_eachFetches() async {
        mock.getStatusDelay = 20_000_000
        mock.getStatusResultBySession["x"] = .fixture(worktree: .fixture(branch: "session/x"))
        mock.getStatusResultBySession["y"] = .fixture(worktree: .fixture(branch: "session/y"))

        let cache = self.cache!
        async let a: Void = cache.ensureLoaded(sessionId: "x")
        async let b: Void = cache.ensureLoaded(sessionId: "y")
        _ = await (a, b)

        XCTAssertEqual(mock.getStatusCallCount, 2)
        XCTAssertEqual(cache.status(for: "x")?.worktree?.branch, "session/x")
        XCTAssertEqual(cache.status(for: "y")?.worktree?.branch, "session/y")
    }

    func test_ensureLoaded_sessionListFetchesEveryMissingSession() async {
        mock.getStatusResultBySession["a"] = .fixture(worktree: .fixture(branch: "session/a"))
        mock.getStatusResultBySession["b"] = .fixture(worktree: .fixture(branch: "session/b"))
        mock.getStatusResultBySession["c"] = .fixture(worktree: .fixture(branch: "session/c"))

        await cache.ensureLoaded(sessionIds: ["a", "b", "a", "c"])

        XCTAssertEqual(mock.getStatusCallCount, 3)
        XCTAssertEqual(cache.status(for: "a")?.worktree?.branch, "session/a")
        XCTAssertEqual(cache.status(for: "b")?.worktree?.branch, "session/b")
        XCTAssertEqual(cache.status(for: "c")?.worktree?.branch, "session/c")
    }

    // T6 — engine protocol error does not poison the cache
    func test_rpcError_leavesStatusNil_andAllowsRetry() async {
        mock.getStatusError = MockWorktreeError.simulated
        await cache.ensureLoaded(sessionId: "x")
        XCTAssertNil(cache.status(for: "x"))
        XCTAssertEqual(mock.getStatusCallCount, 1)

        // T7 — next call retries (no negative cache)
        mock.getStatusError = nil
        mock.getStatusResultBySession["x"] = .fixture()
        await cache.ensureLoaded(sessionId: "x")
        XCTAssertEqual(mock.getStatusCallCount, 2)
        XCTAssertNotNil(cache.status(for: "x"))
    }

    // T8 — invalidate clears entry, next ensureLoaded refetches
    func test_invalidate_clearsEntry_andTriggersRefetch() async {
        mock.getStatusResultBySession["x"] = .fixture()
        await cache.ensureLoaded(sessionId: "x")
        XCTAssertNotNil(cache.status(for: "x"))

        cache.invalidate(sessionId: "x")
        XCTAssertNil(cache.status(for: "x"))

        await cache.ensureLoaded(sessionId: "x")
        XCTAssertEqual(mock.getStatusCallCount, 2)
    }

    // T9 — clearAll wipes every entry
    func test_clearAll_removesEverything() async {
        mock.getStatusResultBySession["x"] = .fixture()
        mock.getStatusResultBySession["y"] = .fixture()
        await cache.ensureLoaded(sessionId: "x")
        await cache.ensureLoaded(sessionId: "y")

        cache.clearAll()

        XCTAssertNil(cache.status(for: "x"))
        XCTAssertNil(cache.status(for: "y"))
    }

    // T10 — concurrency cap ≤ 4 under 20 parallel cold loads
    func test_concurrencyGate_capsInFlightTo4() async {
        mock.getStatusDelay = 30_000_000  // 30 ms — ensures overlap
        for i in 0..<20 { mock.getStatusResultBySession["s\(i)"] = .fixture() }

        let cache = self.cache!
        var tasks: [Task<Void, Never>] = []
        for i in 0..<20 {
            let id = "s\(i)"
            tasks.append(Task { @MainActor in
                await cache.ensureLoaded(sessionId: id)
            })
        }
        for t in tasks { await t.value }

        XCTAssertEqual(mock.getStatusCallCount, 20)
        XCTAssertLessThanOrEqual(mock.peakConcurrent, 4,
            "semaphore must cap concurrency at 4; peak=\(mock.peakConcurrent)")
    }

    // MARK: - Display helpers (Step 3)

    // T12 — no entry
    func test_showIcon_noEntry_false() {
        XCTAssertFalse(cache.shouldShowWorktreeIcon(sessionId: "missing"))
        XCTAssertFalse(cache.shouldShowUncommittedDot(sessionId: "missing"))
    }

    // T13 — on base branch
    func test_showIcon_onBaseBranch_false() {
        cache.set(.fixture(worktree: .fixture(branch: "main", baseBranch: "main")), for: "x")
        XCTAssertFalse(cache.shouldShowWorktreeIcon(sessionId: "x"))
    }

    // T14 — off base branch
    func test_showIcon_offBase_true() {
        cache.set(.fixture(worktree: .fixture(branch: "session/alpha", baseBranch: "main")), for: "x")
        XCTAssertTrue(cache.shouldShowWorktreeIcon(sessionId: "x"))
    }

    // T15 — hasWorktree == false
    func test_showIcon_noWorktree_false() {
        cache.set(.empty, for: "x")
        XCTAssertFalse(cache.shouldShowWorktreeIcon(sessionId: "x"))
    }

    // T16 / T17 — dot tracks hasUncommittedChanges
    func test_uncommittedDot_tracksFlag() {
        cache.set(.fixture(worktree: .fixture(hasUncommittedChanges: true)), for: "x")
        XCTAssertTrue(cache.shouldShowUncommittedDot(sessionId: "x"))

        cache.set(.fixture(worktree: .fixture(hasUncommittedChanges: false)), for: "x")
        XCTAssertFalse(cache.shouldShowUncommittedDot(sessionId: "x"))
    }

    // T18 — non-isolated session is always on-base
    func test_showIcon_passthrough_notIsolated_false() {
        cache.set(.fixture(worktree: .fixture(isolated: false, branch: "main", baseBranch: nil)),
                  for: "x")
        XCTAssertFalse(cache.shouldShowWorktreeIcon(sessionId: "x"))
    }

    // T19 — isolated + nil baseBranch → off-base per existing semantic
    func test_showIcon_isolated_nilBaseBranch_true() {
        cache.set(.fixture(worktree: .fixture(isolated: true, branch: "session/a", baseBranch: nil)),
                  for: "x")
        XCTAssertTrue(cache.shouldShowWorktreeIcon(sessionId: "x"))
    }

    // MARK: - Event application (Step 4)

    // T20 — applyAcquired writes full entry
    func test_applyAcquired_writesFullEntry() async {
        let r = WorktreeAcquiredPlugin.Result(
            path: "/tmp/wt/x",
            branch: "session/x",
            baseCommit: "deadbeef",
            baseBranch: "main"
        )
        cache.applyAcquired(r, sessionId: "x")

        let w = cache.status(for: "x")?.worktree
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.branch, "session/x")
        XCTAssertEqual(w?.baseCommit, "deadbeef")
        XCTAssertEqual(w?.baseBranch, "main")
        XCTAssertEqual(w?.path, "/tmp/wt/x")
        XCTAssertTrue(w?.isolated == true)
        XCTAssertNil(w?.repoRoot)
        XCTAssertEqual(w?.hasUncommittedChanges, false)
        XCTAssertEqual(w?.commitCount, 0)
    }

    // T21 — applyCommit with prior state updates delta fields
    func test_applyCommit_withPrior_updatesDelta() async {
        cache.set(.fixture(worktree: .fixture(
            branch: "session/x", baseBranch: "main",
            hasUncommittedChanges: true, commitCount: 3
        )), for: "x")

        let r = WorktreeCommitPlugin.Result(
            commitHash: "c0ffee",
            message: "wip",
            filesChanged: ["a.swift"],
            insertions: 10,
            deletions: 2,
            totalCommitCount: 4,
            hasUncommittedChanges: false
        )
        await cache.applyCommit(r, sessionId: "x")

        let w = cache.status(for: "x")?.worktree
        XCTAssertEqual(w?.branch, "session/x")
        XCTAssertEqual(w?.baseBranch, "main")
        XCTAssertEqual(w?.hasUncommittedChanges, false)
        XCTAssertEqual(w?.commitCount, 4)
    }

    // T22 — applyCommit without prior state schedules ensureLoaded instead
    func test_applyCommit_noPrior_schedulesEnsureLoaded() async {
        mock.getStatusResultBySession["x"] = .fixture(
            worktree: .fixture(branch: "session/x", commitCount: 7)
        )
        XCTAssertNil(cache.status(for: "x"))

        let r = WorktreeCommitPlugin.Result(
            commitHash: "c0ffee", message: "wip", filesChanged: [],
            insertions: 0, deletions: 0, totalCommitCount: 7,
            hasUncommittedChanges: false
        )
        await cache.applyCommit(r, sessionId: "x")

        XCTAssertEqual(mock.getStatusCallCount, 1)
        XCTAssertEqual(cache.status(for: "x")?.worktree?.commitCount, 7)
    }

    // T23 — applyReleased writes an empty result
    func test_applyReleased_writesEmpty() {
        cache.set(.fixture(), for: "x")
        cache.applyReleased(sessionId: "x")

        let s = cache.status(for: "x")
        XCTAssertEqual(s?.hasWorktree, false)
        XCTAssertNil(s?.worktree)
    }

    // T24 / T25 — refresh invalidates and re-fetches
    func test_refresh_invalidatesAndRefetches() async {
        cache.set(.fixture(worktree: .fixture(branch: "old")), for: "x")
        mock.getStatusResultBySession["x"] = .fixture(worktree: .fixture(branch: "new"))

        await cache.refresh(sessionId: "x")

        XCTAssertEqual(mock.getStatusCallCount, 1)
        XCTAssertEqual(cache.status(for: "x")?.worktree?.branch, "new")
    }

    // MARK: - Global event routing (Step 5)

    // T26 — acquired event mutates cache for correct sessionId
    func test_apply_acquiredEvent_mutatesCache() {
        let r = WorktreeAcquiredPlugin.Result(
            path: "/tmp/wt/x", branch: "session/x",
            baseCommit: "abc", baseBranch: "main"
        )
        let event = makeEvent(type: WorktreeAcquiredPlugin.eventType, sessionId: "x", result: r)

        let handled = cache.apply(event)

        XCTAssertTrue(handled)
        XCTAssertEqual(cache.status(for: "x")?.worktree?.branch, "session/x")
    }

    // T27 — commit event with prior state applies delta
    func test_apply_commitEvent_withPrior_appliesDelta() async {
        cache.set(.fixture(worktree: .fixture(branch: "session/x", hasUncommittedChanges: true)), for: "x")

        let r = WorktreeCommitPlugin.Result(
            commitHash: "c0ffee", message: "x", filesChanged: [],
            insertions: 0, deletions: 0, totalCommitCount: 3, hasUncommittedChanges: false
        )
        let event = makeEvent(type: WorktreeCommitPlugin.eventType, sessionId: "x", result: r)

        let handled = cache.apply(event)
        XCTAssertTrue(handled)

        // Task { await applyCommit(...) } is scheduled — yield to let it run.
        await waitUntil { self.cache.status(for: "x")?.worktree?.commitCount == 3 }
        XCTAssertEqual(cache.status(for: "x")?.worktree?.commitCount, 3)
        XCTAssertEqual(cache.status(for: "x")?.worktree?.hasUncommittedChanges, false)
    }

    // T28 — released event clears worktree
    func test_apply_releasedEvent_clearsWorktree() {
        cache.set(.fixture(), for: "x")
        let r = WorktreeReleasedPlugin.Result(finalCommit: nil, branchPreserved: true, deleted: false)
        let event = makeEvent(type: WorktreeReleasedPlugin.eventType, sessionId: "x", result: r)

        XCTAssertTrue(cache.apply(event))
        XCTAssertEqual(cache.status(for: "x")?.hasWorktree, false)
        XCTAssertNil(cache.status(for: "x")?.worktree)
    }

    // T29 — merged event triggers refresh (refetches via engine protocol)
    func test_apply_mergedEvent_triggersRefresh() async {
        cache.set(.fixture(worktree: .fixture(branch: "old")), for: "x")
        mock.getStatusResultBySession["x"] = .fixture(worktree: .fixture(branch: "main", baseBranch: "main"))
        let r = WorktreeMergedPlugin.Result(sourceBranch: "old", targetBranch: "main",
                                             mergeCommit: "deadbeef", strategy: "merge")
        let event = makeEvent(type: WorktreeMergedPlugin.eventType, sessionId: "x", result: r)

        XCTAssertTrue(cache.apply(event))
        await waitUntil { self.cache.status(for: "x")?.worktree?.branch == "main" }
        XCTAssertEqual(mock.getStatusCallCount, 1)
    }

    // T32 — server.restarting clears everything
    func test_apply_serverRestarting_clearsAll() {
        cache.set(.fixture(), for: "x")
        cache.set(.fixture(), for: "y")
        let r = ServerRestartingPlugin.Result(reason: "deploy", commit: "abc", restartExpectedMs: 1000)
        let event: ParsedEventV2 = .plugin(
            type: ServerRestartingPlugin.eventType,
            event: ParsedEventData(value: ()),
            sessionId: nil,
            sequence: nil,
            transform: { r }
        )

        XCTAssertTrue(cache.apply(event))
        XCTAssertNil(cache.status(for: "x"))
        XCTAssertNil(cache.status(for: "y"))
    }

    // T-ignore: unrelated events return false and don't mutate
    func test_apply_unrelatedEvent_returnsFalse() {
        cache.set(.fixture(), for: "x")
        let event: ParsedEventV2 = .unknown("agent.text_delta")
        XCTAssertFalse(cache.apply(event))
        XCTAssertNotNil(cache.status(for: "x"))
    }

    // MARK: - Event fixture helpers

    private func makeEvent(type: String, sessionId: String?, result: any EventResult) -> ParsedEventV2 {
        .plugin(
            type: type,
            event: ParsedEventData(value: ()),
            sessionId: sessionId,
            sequence: nil,
            transform: { result }
        )
    }

    /// Poll for a condition to become true, up to ~500 ms.
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<50 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
