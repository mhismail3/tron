import Foundation
import Testing
@testable import TronMobile

/// Behavioral matrix for the `GitTileGating` value type. Each test
/// pins one row of the truth table that the Source Control sheet's
/// tile-enabled booleans encode. Drift between server-side preconditions
/// and client gating is the whole reason the type exists; these tests
/// catch that drift.
@Suite("GitTileGating matrix")
struct GitTileGatingTests {

    // MARK: - Builders (keep tests readable)

    private func info(
        branch: String = "feature/x",
        baseBranch: String? = "main",
        isolated: Bool = true,
        hasUncommittedChanges: Bool? = false,
        commitCount: Int? = 0,
        isMerged: Bool? = false
    ) -> WorktreeInfo {
        WorktreeInfo(
            isolated: isolated,
            branch: branch,
            baseCommit: "deadbeef",
            path: "/repo/.worktrees/x",
            baseBranch: baseBranch,
            repoRoot: "/repo",
            hasUncommittedChanges: hasUncommittedChanges,
            commitCount: commitCount,
            isMerged: isMerged
        )
    }

    private func divergence(
        aheadMain: UInt64? = 0,
        behindMain: UInt64? = 0,
        aheadOrigin: UInt64? = 0,
        behindOrigin: UInt64? = 0,
        hasOrigin: Bool = true
    ) -> RepoDivergence {
        // RepoDivergence has no public init — build via JSON round-trip.
        struct Wire: Encodable {
            let aheadMain: UInt64?
            let behindMain: UInt64?
            let aheadOrigin: UInt64?
            let behindOrigin: UInt64?
            let hasOrigin: Bool
        }
        let wire = Wire(
            aheadMain: aheadMain,
            behindMain: behindMain,
            aheadOrigin: aheadOrigin,
            behindOrigin: behindOrigin,
            hasOrigin: hasOrigin
        )
        let data = try! JSONEncoder().encode(wire)
        return try! JSONDecoder().decode(RepoDivergence.self, from: data)
    }

    // MARK: - Loading state

    @Test("All inputs nil → every tile disabled")
    func loadingStateDisablesEverything() {
        let g = GitTileGating()
        #expect(g.isWorkflowFree == true)  // no blockers means free
        #expect(g.isCommitEnabled == false)
        #expect(g.isMergeEnabled == false)
        #expect(g.isSessionsEnabled == false)
        #expect(g.isRebaseEnabled == false)
        #expect(g.isPullEnabled == false)
        #expect(g.isPushEnabled == false)
    }

    // MARK: - Workflow gate

    @Test("Lock holder blocks every mutating tile")
    func lockHolderBlocksMutatingTiles() {
        let g = GitTileGating(
            hasLockHolder: true,
            worktree: info(hasUncommittedChanges: true, commitCount: 3),
            divergence: divergence(behindMain: 5, behindOrigin: 5),
            protectedBranches: [],
            repoSessionCount: 2
        )
        #expect(g.isWorkflowFree == false)
        #expect(g.isCommitEnabled == false)
        #expect(g.isMergeEnabled == false)
        #expect(g.isRebaseEnabled == false)
        #expect(g.isPullEnabled == false)
        #expect(g.isPushEnabled == false)
        // Sessions tile is purely informational — stays enabled.
        #expect(g.isSessionsEnabled == true)
    }

    @Test("Conflict banner blocks every mutating tile")
    func conflictBannerBlocksMutatingTiles() {
        let g = GitTileGating(
            hasConflictBanner: true,
            worktree: info(hasUncommittedChanges: true)
        )
        #expect(g.isWorkflowFree == false)
        #expect(g.isCommitEnabled == false)
    }

    @Test("Pending merge blocks every mutating tile")
    func pendingMergeBlocksMutatingTiles() {
        let g = GitTileGating(
            hasPendingMerge: true,
            worktree: info(hasUncommittedChanges: true)
        )
        #expect(g.isWorkflowFree == false)
        #expect(g.isCommitEnabled == false)
    }

    // MARK: - Commit

    @Test("Commit enabled when dirty + workflow free")
    func commitEnabledWhenDirty() {
        let g = GitTileGating(
            worktree: info(hasUncommittedChanges: true)
        )
        #expect(g.isCommitEnabled == true)
    }

    @Test("Commit enabled for dirty passthrough checkout")
    func commitEnabledForDirtyPassthroughCheckout() {
        let g = GitTileGating(
            worktree: info(isolated: false, hasUncommittedChanges: true)
        )
        #expect(g.isCommitEnabled == true)
    }

    @Test("Commit disabled when clean")
    func commitDisabledWhenClean() {
        let g = GitTileGating(worktree: info(hasUncommittedChanges: false))
        #expect(g.isCommitEnabled == false)
    }

    // MARK: - Merge

    @Test("Merge enabled with commits, clean, off-base")
    func mergeEnabledHappyPath() {
        let g = GitTileGating(
            worktree: info(branch: "feature/x", baseBranch: "main", commitCount: 3),
            divergence: divergence()
        )
        #expect(g.isMergeEnabled == true)
    }

    @Test("Merge disabled when on base branch")
    func mergeDisabledOnBase() {
        let g = GitTileGating(
            worktree: info(branch: "main", baseBranch: "main", commitCount: 3)
        )
        #expect(g.isMergeEnabled == false)
    }

    @Test("Merge disabled when no commits to integrate")
    func mergeDisabledNoCommits() {
        let g = GitTileGating(
            worktree: info(commitCount: 0)
        )
        #expect(g.isMergeEnabled == false)
    }

    @Test("Merge disabled when working tree dirty")
    func mergeDisabledDirty() {
        let g = GitTileGating(
            worktree: info(hasUncommittedChanges: true, commitCount: 3)
        )
        #expect(g.isMergeEnabled == false)
    }

    @Test("Merge disabled for passthrough checkout")
    func mergeDisabledForPassthroughCheckout() {
        let g = GitTileGating(
            worktree: info(isolated: false, hasUncommittedChanges: false, commitCount: 3)
        )
        #expect(g.isMergeEnabled == false)
        #expect(g.reason(for: .merge)?.contains("isolated session branches") == true)
    }

    // MARK: - Sessions

    @Test("Sessions disabled when no peers")
    func sessionsDisabledNoPeers() {
        let g = GitTileGating(repoSessionCount: 0)
        #expect(g.isSessionsEnabled == false)
    }

    @Test("Sessions enabled with at least one peer")
    func sessionsEnabledWithPeers() {
        let g = GitTileGating(repoSessionCount: 1)
        #expect(g.isSessionsEnabled == true)
    }

    // MARK: - Rebase

    @Test("Rebase enabled when behind main")
    func rebaseEnabledWhenBehind() {
        let g = GitTileGating(
            worktree: info(),
            divergence: divergence(behindMain: 3)
        )
        #expect(g.isRebaseEnabled == true)
    }

    @Test("Rebase disabled for passthrough checkout")
    func rebaseDisabledForPassthroughCheckout() {
        let g = GitTileGating(
            worktree: info(isolated: false),
            divergence: divergence(behindMain: 3)
        )
        #expect(g.isRebaseEnabled == false)
        #expect(g.reason(for: .rebase)?.contains("isolated session branches") == true)
    }

    @Test("Rebase disabled when not behind main")
    func rebaseDisabledWhenCaughtUp() {
        let g = GitTileGating(divergence: divergence(behindMain: 0))
        #expect(g.isRebaseEnabled == false)
    }

    // MARK: - Pull

    @Test("Pull enabled when behind origin and remote present")
    func pullEnabledWhenBehindOrigin() {
        let g = GitTileGating(
            divergence: divergence(behindOrigin: 5, hasOrigin: true)
        )
        #expect(g.isPullEnabled == true)
    }

    @Test("Pull disabled when no origin remote")
    func pullDisabledWithoutOrigin() {
        let g = GitTileGating(
            divergence: divergence(behindOrigin: 5, hasOrigin: false)
        )
        #expect(g.isPullEnabled == false)
    }

    @Test("Pull disabled when origin caught up")
    func pullDisabledWhenSynced() {
        let g = GitTileGating(
            divergence: divergence(behindOrigin: 0, hasOrigin: true)
        )
        #expect(g.isPullEnabled == false)
    }

    // MARK: - Push

    @Test("Push enabled with remote, branch not protected")
    func pushEnabledHappyPath() {
        let g = GitTileGating(
            worktree: info(branch: "feature/x"),
            divergence: divergence(hasOrigin: true),
            protectedBranches: ["main", "master"]
        )
        #expect(g.isPushEnabled == true)
    }

    @Test("Push enabled for passthrough checkout when remote exists")
    func pushEnabledForPassthroughCheckout() {
        let g = GitTileGating(
            worktree: info(branch: "feature/x", isolated: false),
            divergence: divergence(hasOrigin: true),
            protectedBranches: ["main", "master"]
        )
        #expect(g.isPushEnabled == true)
    }

    @Test("Push disabled while protected-branches list is loading")
    func pushDisabledWhileLoading() {
        let g = GitTileGating(
            worktree: info(branch: "feature/x"),
            divergence: divergence(hasOrigin: true),
            protectedBranches: nil
        )
        #expect(g.isPushEnabled == false)
    }

    @Test("Push disabled when current branch is protected (exact match)")
    func pushDisabledOnProtected() {
        let g = GitTileGating(
            worktree: info(branch: "main"),
            divergence: divergence(hasOrigin: true),
            protectedBranches: ["main"]
        )
        #expect(g.isPushEnabled == false)
    }

    @Test("Push disabled when current branch is protected (mixed case)")
    func pushDisabledOnProtectedCaseInsensitive() {
        let g = GitTileGating(
            worktree: info(branch: "Main"),
            divergence: divergence(hasOrigin: true),
            protectedBranches: ["main"]
        )
        #expect(g.isPushEnabled == false)
    }

    @Test("Push disabled when current branch is protected (whitespace)")
    func pushDisabledOnProtectedWithWhitespace() {
        let g = GitTileGating(
            worktree: info(branch: " main "),
            divergence: divergence(hasOrigin: true),
            protectedBranches: ["main"]
        )
        #expect(g.isPushEnabled == false)
    }

    @Test("Push disabled with no remote configured")
    func pushDisabledWithoutOrigin() {
        let g = GitTileGating(
            worktree: info(branch: "feature/x"),
            divergence: divergence(hasOrigin: false),
            protectedBranches: []
        )
        #expect(g.isPushEnabled == false)
    }

    @Test("Push disabled when current branch is empty/blank")
    func pushDisabledOnBlankBranch() {
        let g = GitTileGating(
            worktree: info(branch: "   "),
            divergence: divergence(hasOrigin: true),
            protectedBranches: []
        )
        #expect(g.isPushEnabled == false)
    }

    // MARK: - H12: reason(for:) + isEnabled(_:)

    @Test("isEnabled(tile) mirrors each boolean field")
    func isEnabledMirrorsBooleans() {
        let g = GitTileGating(
            worktree: info(hasUncommittedChanges: true, commitCount: 2),
            divergence: divergence(behindMain: 1, behindOrigin: 1, hasOrigin: true),
            protectedBranches: [],
            repoSessionCount: 2
        )
        #expect(g.isEnabled(.commit)   == g.isCommitEnabled)
        #expect(g.isEnabled(.merge)    == g.isMergeEnabled)
        #expect(g.isEnabled(.sessions) == g.isSessionsEnabled)
        #expect(g.isEnabled(.rebase)   == g.isRebaseEnabled)
        #expect(g.isEnabled(.pull)     == g.isPullEnabled)
        #expect(g.isEnabled(.push)     == g.isPushEnabled)
    }

    @Test("reason(for:) returns nil for every enabled tile")
    func reasonNilWhenEnabled() {
        let g = GitTileGating(
            worktree: info(branch: "feature/x", hasUncommittedChanges: true, commitCount: 2),
            divergence: divergence(behindMain: 1, behindOrigin: 1, hasOrigin: true),
            protectedBranches: [],
            repoSessionCount: 3
        )
        // Commit + merge mutually exclude (merge wants a clean tree).
        // Build a separate config for merge.
        let mergeConfig = GitTileGating(
            worktree: info(branch: "feature/x", hasUncommittedChanges: false, commitCount: 2),
            divergence: divergence(hasOrigin: true),
            protectedBranches: [],
            repoSessionCount: 3
        )
        // Commit/sessions/rebase/pull/push all enabled in g.
        #expect(g.reason(for: .commit)   == nil)
        #expect(g.reason(for: .sessions) == nil)
        #expect(g.reason(for: .rebase)   == nil)
        #expect(g.reason(for: .pull)     == nil)
        #expect(g.reason(for: .push)     == nil)
        #expect(mergeConfig.reason(for: .merge) == nil)
    }

    @Test("Workflow-free block reason takes precedence over per-tile reasons")
    func workflowFreeBlockTakesPrecedence() {
        let g = GitTileGating(
            hasLockHolder: true,
            worktree: info(hasUncommittedChanges: true, commitCount: 2),
            divergence: divergence(behindMain: 1, behindOrigin: 1, hasOrigin: true),
            protectedBranches: [],
            repoSessionCount: 2
        )
        // Every tile disabled, all reasons should point at the shared gate.
        for tile: GitTile in [.commit, .merge, .rebase, .pull, .push] {
            #expect(
                g.reason(for: tile)?.contains("lock") == true,
                "workflow-free reason missing for tile"
            )
        }
    }

    @Test("Pending-merge reason mentions conflict resolver")
    func pendingMergeReasonHasActionableHint() {
        let g = GitTileGating(hasPendingMerge: true)
        let r = g.reason(for: .commit) ?? ""
        #expect(r.contains("Conflict Resolver"))
    }

    @Test("Push reason names the protected branch")
    func pushReasonNamesProtectedBranch() {
        let g = GitTileGating(
            worktree: info(branch: "main"),
            divergence: divergence(hasOrigin: true),
            protectedBranches: ["main", "master"]
        )
        #expect(g.isPushEnabled == false)
        let r = g.reason(for: .push) ?? ""
        #expect(r.contains("main"))
    }

    @Test("Merge reason on base branch is distinct from conflict reason")
    func mergeReasonOnBaseBranchIsSpecific() {
        let g = GitTileGating(
            worktree: info(branch: "main", baseBranch: "main", commitCount: 0)
        )
        let r = g.reason(for: .merge) ?? ""
        #expect(r.contains("base branch"))
    }

    @Test("Loading state yields specific reasons, not nil")
    func loadingStateHasReasons() {
        // Zero inputs — loading collapse.
        let g = GitTileGating()
        #expect(g.reason(for: .merge)?.contains("loading") == true)
        #expect(g.reason(for: .pull)?.contains("loading") == true)
        #expect(g.reason(for: .rebase)?.contains("loading") == true)
    }
}
