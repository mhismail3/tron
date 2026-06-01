import Foundation

/// Which git workflow tile we're asking about — used by
/// [`GitTileGating.reason(for:)`] to surface a single user-facing
/// explanation when a tile is disabled. Each case maps 1-to-1 to a
/// tile in the Source Control sheet.
enum GitTile: Equatable, Sendable {
    case commit
    case merge
    case sessions
    case rebase
    case pull
    case push
}

/// Pure value-type that captures whether each git workflow tile in the
/// Source Control sheet should be enabled given the current
/// worktree/divergence/lock state. Mirrors the server-side preconditions
/// for each `git.*` / `worktree.*` engine protocol so we fail fast (greyed-out tile)
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

    /// Captured inputs — kept around so `reason(for:)` can produce an
    /// accurate human-readable explanation for a disabled tile
    /// without a second round of re-derivation that might diverge
    /// from the enabled flags above.
    private let hasLockHolder: Bool
    private let hasPendingMerge: Bool
    private let hasConflictBanner: Bool
    private let worktree: WorktreeInfo?
    private let divergence: RepoDivergence?
    private let protectedBranches: [String]?
    private let repoSessionCount: Int

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
        self.hasLockHolder = hasLockHolder
        self.hasPendingMerge = hasPendingMerge
        self.hasConflictBanner = hasConflictBanner
        self.worktree = worktree
        self.divergence = divergence
        self.protectedBranches = protectedBranches
        self.repoSessionCount = repoSessionCount
        let workflowFree = !hasLockHolder && !hasPendingMerge && !hasConflictBanner
        self.isWorkflowFree = workflowFree

        // Commit
        self.isCommitEnabled =
            workflowFree && (worktree?.hasUncommittedChanges == true)

        // Merge
        if let info = worktree,
            workflowFree,
            info.isolated,
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
            workflowFree
            && worktree?.isolated == true
            && ((divergence?.behindMain ?? 0) > 0)

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

    // MARK: - Per-tile query

    /// Whether the given tile is currently enabled.
    func isEnabled(_ tile: GitTile) -> Bool {
        switch tile {
        case .commit:   return isCommitEnabled
        case .merge:    return isMergeEnabled
        case .sessions: return isSessionsEnabled
        case .rebase:   return isRebaseEnabled
        case .pull:     return isPullEnabled
        case .push:     return isPushEnabled
        }
    }

    /// Human-readable explanation for WHY a tile is disabled, suitable
    /// for a tooltip / accessibility hint. Returns `nil` when the tile
    /// is enabled.
    ///
    /// The workflow-free gate (lock / pending merge / conflict banner)
    /// takes precedence because it's the clearest signal: nothing will
    /// work until the user resolves that state, regardless of what
    /// tile they tap. Per-tile reasons follow, ordered by specificity.
    func reason(for tile: GitTile) -> String? {
        if isEnabled(tile) { return nil }

        if let shared = workflowBlockReason() {
            return shared
        }

        switch tile {
        case .commit:
            return "Nothing to commit — no uncommitted changes."
        case .merge:
            if worktree == nil { return "Worktree status is still loading…" }
            if worktree?.isolated == false {
                return "Merge is only available for isolated session branches."
            }
            if worktree?.isOnBaseBranch == true {
                return "Merge is unavailable on the base branch."
            }
            if (worktree?.commitCount ?? 0) == 0 {
                return "Nothing to integrate — no commits on this branch."
            }
            if worktree?.hasUncommittedChanges == true {
                return "Commit or stash uncommitted changes before merging."
            }
            return "Merge preconditions not met."
        case .sessions:
            return "No peer sessions in this repo yet."
        case .rebase:
            if worktree == nil { return "Worktree status is still loading…" }
            if worktree?.isolated == false {
                return "Rebase is only available for isolated session branches."
            }
            if divergence == nil { return "Divergence info still loading…" }
            return "Already up to date with the base branch."
        case .pull:
            if divergence == nil { return "Divergence info still loading…" }
            if divergence?.hasOrigin != true {
                return "No remote configured for this repo."
            }
            return "Local main is already up to date with origin."
        case .push:
            if divergence?.hasOrigin != true {
                return "No remote configured for this repo."
            }
            if worktree?.branch == nil || worktree?.branch.isEmpty == true {
                return "Current branch is not yet known."
            }
            if protectedBranches == nil {
                return "Protected-branch list still loading…"
            }
            if let branch = worktree?.branch.trimmingCharacters(in: .whitespaces).lowercased(),
               let raws = protectedBranches {
                let protected = Set(raws.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                if protected.contains(branch) {
                    return "\(branch) is a protected branch. Push manually or disable the guard in Settings."
                }
            }
            return "Push preconditions not met."
        }
    }

    /// Shared workflow-gate reason: lock / pending merge / conflict.
    /// Returns nil when none of those are asserted.
    private func workflowBlockReason() -> String? {
        if hasLockHolder {
            return "Another session is holding the repo lock. Try again once it releases."
        }
        if hasPendingMerge {
            return "A merge is pending resolution — use the Conflict Resolver to continue."
        }
        if hasConflictBanner {
            return "Unresolved conflicts detected — use the Conflict Resolver to continue."
        }
        return nil
    }
}
