import Foundation

/// Holds per-session git workflow signals that are surfaced in the Source
/// Control sheet — repo-wide lock holder, pending-merge crash recovery
/// state, conflict banner, and a divergence-staleness tick.
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
    // Conflict banner.
    // Populated by `worktree.conflict_detected`; cleared once the resolver
    // either succeeds (auto-dismiss via `merge_continued`) or aborts.
    // ─────────────────────────────────────────────────────────────────────

    /// Conflict count + strategy waiting for the resolver subagent.
    var conflictBanner: ConflictBanner?

    // ─────────────────────────────────────────────────────────────────────
    // Divergence-chip staleness signal.
    // Incremented on `repo.main_advanced` and after sync/finalize/push so
    // observing sheets re-fetch `repo.getDivergence` / `repo.listSessions`.
    // ─────────────────────────────────────────────────────────────────────

    var divergenceRefreshTick: Int = 0

    /// Mark divergence chips dirty so sheets fetch fresh data.
    func markDivergenceStale() {
        divergenceRefreshTick &+= 1
    }

    init() {}
}

// MARK: - Banner payloads

struct PendingMergeBanner: Equatable {
    let sourceBranch: String
    let targetBranch: String
    let strategy: String
    let startedAtMs: UInt64
    let autoAbortAtMs: UInt64
}

struct ConflictBanner: Equatable {
    let sourceBranch: String
    let targetBranch: String
    let paths: [String]
}
