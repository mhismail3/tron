import XCTest
@testable import TronMobile

@MainActor
final class WorktreeIsolationStateTests: XCTestCase {

    private var cache: WorktreeStatusCache!

    override func setUp() async throws {
        cache = WorktreeStatusCache(fetch: { _ in
            WorktreeGetStatusResult(hasWorktree: false, worktree: nil)
        })
    }

    override func tearDown() async throws { cache = nil }

    // T33 — state reads from cache
    func test_status_readsFromCache() {
        cache.set(.fixture(worktree: .fixture(branch: "session/a")), for: "a")
        let state = WorktreeIsolationState(sessionId: "a", cache: cache)

        XCTAssertEqual(state.worktree?.branch, "session/a")
        XCTAssertTrue(state.hasWorktree)
        XCTAssertNotNil(state.status)
    }

    // T34 — state reflects cache updates
    func test_state_reflectsCacheUpdates() {
        let state = WorktreeIsolationState(sessionId: "a", cache: cache)
        XCTAssertNil(state.worktree)

        cache.set(.fixture(worktree: .fixture(branch: "session/a")), for: "a")
        XCTAssertEqual(state.worktree?.branch, "session/a")

        cache.applyReleased(sessionId: "a")
        XCTAssertFalse(state.hasWorktree)
        XCTAssertNil(state.worktree)
    }

    // T35 — two states for different sessions read independent slices
    func test_multipleStates_readIndependentSlices() {
        cache.set(.fixture(worktree: .fixture(branch: "session/a")), for: "a")
        cache.set(.fixture(worktree: .fixture(branch: "session/b")), for: "b")

        let stateA = WorktreeIsolationState(sessionId: "a", cache: cache)
        let stateB = WorktreeIsolationState(sessionId: "b", cache: cache)

        XCTAssertEqual(stateA.worktree?.branch, "session/a")
        XCTAssertEqual(stateB.worktree?.branch, "session/b")
    }

    // isLoading remains a per-state flag
    func test_isLoading_isLocal() {
        let a = WorktreeIsolationState(sessionId: "a", cache: cache)
        let b = WorktreeIsolationState(sessionId: "b", cache: cache)

        a.isLoading = true
        XCTAssertTrue(a.isLoading)
        XCTAssertFalse(b.isLoading)
    }
}
