import Foundation

/// Holds per-session git workflow signals that are surfaced in the Source
/// Control sheet — repo-wide lock holder, pending-merge crash recovery
/// state, conflict banner, and a source-control refresh tick.
///
/// The SCM sheet reads this state to render the header badges and to route
/// conflict-resolver / pending-merge banners. Handlers in
/// `ChatViewModel+Worktree.swift` and `ChatViewModel+Repo.swift` write here
/// in response to server events.
@Observable
@MainActor
final class GitWorkflowState {

    // ─────────────────────────────────────────────────────────────────────
    // Repo-wide lock (another session holds `syncMain` or `finalizeSession`).
    // Populated by `repo.lock_acquired` / cleared by `repo.lock_released`.
    // ─────────────────────────────────────────────────────────────────────

    /// Session + operation currently holding the per-repo lock, if any.
    var lockHolder: RepoSessionLock?

    // ─────────────────────────────────────────────────────────────────────
    // Pending merge crash recovery.
    // Populated by `worktree.pending_merge_detected` on coordinator startup.
    // ─────────────────────────────────────────────────────────────────────

    /// Crash-recovered merge awaiting a user decision. Cleared on
    /// `merge_continued` / `merge_aborted`.
    var pendingMerge: PendingMergeBanner?

    // ─────────────────────────────────────────────────────────────────────
    // Unified conflict banner.
    //
    // Populated by `worktree.conflict_detected` (fires for any origin:
    // `finalize`, `rebase_on_main`, or `stash_pop`). Cleared by
    // `worktree.merge_continued` / `worktree.merge_aborted`, or by
    // `worktree.conflict_resolved` when the final conflict clears.
    //
    // The banner is the SINGLE source of "there are conflicts, user action
    // required". The `origin` field drives contextual copy in the header
    // and the resolver sheet.
    // ─────────────────────────────────────────────────────────────────────

    /// Unresolved conflicts awaiting user action (resolve or abort).
    var conflictBanner: ConflictBanner?

    // ─────────────────────────────────────────────────────────────────────
    // Source-control staleness signal.
    // Incremented on git/worktree events that can change the current branch,
    // dirty state, commit counts, peer-session list, or divergence chips.
    // ─────────────────────────────────────────────────────────────────────

    var sourceControlRefreshTick: Int = 0

    /// Mark source-control projections dirty so open sheets fetch fresh data.
    func markSourceControlStale() {
        sourceControlRefreshTick &+= 1
    }

    init() {}
}

// MARK: - Banner payloads

struct PendingMergeBanner: Equatable {
    let sourceBranch: String
    let targetBranch: String
    let strategy: String
    let origin: ConflictOrigin
    let startedAtMs: UInt64
    let autoAbortAtMs: UInt64
}

/// Origin of a conflict. Drives copy and action labels in the resolver.
///
/// Wire values match the server's `MergeOrigin::as_str()` output.
enum ConflictOrigin: String, Equatable, Sendable {
    case finalize
    case rebaseOnMain = "rebase_on_main"
    case stashPop = "stash_pop"

    /// Parse the server wire string. Unknown values are a contract violation
    /// and must be rejected by the caller instead of coerced into a workflow.
    init?(wire: String) {
        guard let parsed = ConflictOrigin(rawValue: wire) else { return nil }
        self = parsed
    }

    /// Short human-readable label for banners ("Merge", "Rebase on main",
    /// "Stashed changes"). Used in the status header banner.
    var shortLabel: String {
        switch self {
        case .finalize: "Merge into main"
        case .rebaseOnMain: "Rebase on main"
        case .stashPop: "Restoring stashed changes"
        }
    }

    /// One-sentence description of what's in progress and what the user
    /// is being asked to do. Used in the resolver sub-sheet hero.
    var resolverDescription: String {
        switch self {
        case .finalize:
            "A merge into main is in progress and needs manual edits. Tap the wand to spawn a subagent that will read each file, choose ours/theirs or hand-edit, and commit the resolution — or abort to roll back."
        case .rebaseOnMain:
            "A rebase of this session onto main hit conflicts. Tap the wand to spawn a subagent that will resolve the conflicts and continue the rebase — or abort to restore your session's previous tip."
        case .stashPop:
            "The rebase finished, but restoring your uncommitted changes hit conflicts. Tap the wand to spawn a subagent to resolve the conflicts (and drop the stash) — or abort to throw the stash-pop away. The stash itself is preserved on the stash stack either way."
        }
    }

    /// Banner subtitle shown in the source control header.
    var bannerSubtitle: String {
        switch self {
        case .finalize: "Merge conflicts need your attention"
        case .rebaseOnMain: "Rebase conflicts need your attention"
        case .stashPop: "Stashed changes conflict with the rebase"
        }
    }

    /// Confirmation message for the abort button.
    var abortConfirmationMessage: String {
        switch self {
        case .finalize:
            "Abort the merge and restore your branch to its pre-merge state?"
        case .rebaseOnMain:
            "Abort the rebase and restore your branch to its pre-rebase state?"
        case .stashPop:
            "Discard the half-applied stash pop? Your stash stays on the stack for manual recovery."
        }
    }
}

struct ConflictBanner: Equatable {
    let sourceBranch: String
    let targetBranch: String
    let origin: ConflictOrigin
    let paths: [String]

    /// Construct from a server event — parses the origin string.
    init?(sourceBranch: String, targetBranch: String, origin: String, paths: [String]) {
        guard let parsedOrigin = ConflictOrigin(wire: origin) else { return nil }
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.origin = parsedOrigin
        self.paths = paths
    }

    /// Typed-origin convenience initialiser for callers already holding
    /// a `ConflictOrigin` (e.g. tests, synthetic state).
    init(
        sourceBranch: String,
        targetBranch: String,
        origin: ConflictOrigin,
        paths: [String]
    ) {
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.origin = origin
        self.paths = paths
    }
}
