import Foundation

/// Pure value-type that captures whether each git workflow tile in the
/// Source Control sheet should be enabled given the current
/// worktree/divergence/lock state. Mirrors the server-side preconditions
/// for each `git.*` / `worktree.*` RPC so we fail fast (greyed-out tile)
/// instead of round-tripping just to surface an error popup.
///
/// Construct with the relevant signals; read the booleans. The struct
/// is `Equatable` so SwiftUI can cheaply re-derive on input changes.
///
/// Tests: see `Tests/ViewModels/State/GitTileGatingTests.swift`.
struct GitTileGating: Equatable {

    /// True when no peer session holds the repo-wide lock, no conflict
    /// banner is pending resolution, and no crash-recovered merge is
    /// awaiting user action. Every mutating tile gates on this.
    let isWorkflowFree: Bool

    /// Commit tile — needs uncommitted changes + workflow free.
    let isCommitEnabled: Bool

    /// Merge tile — needs commits to integrate, a clean tree, and the
    /// session NOT sitting on its own base branch.
    let isMergeEnabled: Bool

    /// Sessions tile — true iff the repo has at least one peer session
    /// to switch to. Doesn't require workflow-free state (informational).
    let isSessionsEnabled: Bool

    /// Rebase tile — needs the session demonstrably behind main and
    /// workflow free.
    let isRebaseEnabled: Bool

    /// Pull (syncMain) tile — needs local main behind origin main, a
    /// remote configured, and workflow free.
    let isPullEnabled: Bool

    /// Push tile — needs a remote configured, a current branch that is
    /// NOT in the user's protected list, and workflow free. While the
    /// protected-branch list is loading (`nil`), Push is gated off so
    /// we never authorize a push to a branch the user marked protected.
    let isPushEnabled: Bool

    /// All inputs are optional / sensibly-defaulted so the "loading"
    /// state (everything `nil`) collapses to "every tile disabled".
    /// Protected branches are normalized (lowercased + trimmed) so
    /// `"Main"`, `" main "`, and `"main"` all match `{ "main" }`.
    init(
        hasLockHolder: Bool = false,
        hasPendingMerge: Bool = false,
        hasConflictBanner: Bool = false,
        worktree: WorktreeInfo? = nil,
        divergence: RepoDivergence? = nil,
        protectedBranches: [String]? = nil,
        repoSessionCount: Int = 0
    ) {
        let workflowFree = !hasLockHolder && !hasPendingMerge && !hasConflictBanner
        self.isWorkflowFree = workflowFree

        // Commit
        self.isCommitEnabled =
            workflowFree && (worktree?.hasUncommittedChanges == true)

        // Merge
        if let info = worktree,
            workflowFree,
            !info.isOnBaseBranch,
            (info.commitCount ?? 0) > 0,
            info.hasUncommittedChanges != true
        {
            self.isMergeEnabled = true
        } else {
            self.isMergeEnabled = false
        }

        // Sessions — purely informational, no workflow gate.
        self.isSessionsEnabled = repoSessionCount > 0

        // Rebase
        self.isRebaseEnabled =
            workflowFree && ((divergence?.behindMain ?? 0) > 0)

        // Pull
        self.isPullEnabled =
            workflowFree
            && (divergence?.hasOrigin == true)
            && ((divergence?.behindOrigin ?? 0) > 0)

        // Push
        if workflowFree,
            divergence?.hasOrigin == true,
            let branchRaw = worktree?.branch,
            case let branch = branchRaw.trimmingCharacters(in: .whitespaces).lowercased(),
            !branch.isEmpty,
            let protectedRaw = protectedBranches
        {
            let protected: Set<String> = Set(
                protectedRaw.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            )
            self.isPushEnabled = !protected.contains(branch)
        } else {
            self.isPushEnabled = false
        }
    }
}
