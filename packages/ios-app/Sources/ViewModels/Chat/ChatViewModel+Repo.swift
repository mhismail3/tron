import Foundation

// MARK: - Repo Event Handlers

extension ChatViewModel {

    /// A peer session acquired the per-repo lock for syncMain/finalizeSession.
    /// The Source Control sheet in this session should show a waiting badge.
    func handleRepoLockAcquired(_ result: RepoLockAcquiredPlugin.Result) {
        // Only surface the badge when ANOTHER session holds the lock.
        guard result.holderSessionId != sessionId else { return }
        gitWorkflowState.lockHolder = RepoSessionLock(
            sessionId: result.holderSessionId,
            op: result.op
        )
    }

    /// The per-repo lock was released. If this session had a pending op, the
    /// UI will auto-proceed on the next tick.
    func handleRepoLockReleased(_ result: RepoLockReleasedPlugin.Result) {
        // Clear only if the release matches our cached holder — out-of-order
        // events shouldn't clobber a fresh acquire from a different session.
        if gitWorkflowState.lockHolder?.sessionId == result.holderSessionId {
            gitWorkflowState.lockHolder = nil
        }
    }

    /// Main advanced in this repo (likely from a peer session's finalize).
    /// Refresh worktree status so divergence chips reflect the new drift.
    func handleRepoMainAdvanced(_ result: RepoMainAdvancedPlugin.Result) {
        gitWorkflowState.markSourceControlStale()
        Task { await requestWorktreeStatus() }
    }
}
