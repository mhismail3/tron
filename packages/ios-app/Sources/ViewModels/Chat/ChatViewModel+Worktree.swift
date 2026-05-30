import Foundation

// MARK: - Worktree Engine Capability Methods

extension ChatViewModel {

    /// Request worktree status from server (fire-and-forget, swallows errors).
    /// Writes to the shared cache so both toolbar and sidebar observe the update.
    func requestWorktreeStatus() async {
        worktreeState.isLoading = true
        defer { worktreeState.isLoading = false }
        await worktreeState.cache.refresh(sessionId: sessionId)
    }

    // MARK: - Real-time WebSocket Event Handlers

    func handleWorktreeAcquired(_ result: WorktreeAcquiredPlugin.Result) {
        worktreeState.cache.applyAcquired(result, sessionId: sessionId)
        gitWorkflowState.markSourceControlStale()
    }

    func handleWorktreeCommit(_ result: WorktreeCommitPlugin.Result) {
        gitWorkflowState.markSourceControlStale()
        Task { await worktreeState.cache.applyCommit(result, sessionId: sessionId) }
    }

    func handleWorktreeMerged(_ result: WorktreeMergedPlugin.Result) {
        refreshSourceControlStatus()
    }

    func handleWorktreeReleased(_ result: WorktreeReleasedPlugin.Result) {
        worktreeState.cache.applyReleased(sessionId: sessionId)
        gitWorkflowState.markSourceControlStale()
    }

    // MARK: - Git Workflow Event Handlers

    func handleWorktreeMainSynced(_ result: WorktreeMainSyncedPlugin.Result) {
        // Local main moved or was confirmed current; open Source Control
        // surfaces must reload divergence/action gating from server truth.
        gitWorkflowState.markSourceControlStale()
        logDebug("worktree.main_synced advancedBy=\(result.advancedBy)")
    }

    func handleWorktreeSessionFinalized(_ result: WorktreeSessionFinalizedPlugin.Result) {
        // Rebranch occurred — refresh worktree status to pick up new branch/base.
        refreshSourceControlStatus()
        // Route to APNs-style local notification if app is backgrounded.
        GitNotificationRouter.shared.postFinalizeCompleted(
            sessionId: sessionId,
            sourceBranch: result.sourceBranch,
            targetBranch: result.targetBranch,
            mergeCommit: result.mergeCommit,
            success: true
        )
    }

    func handleWorktreeMergeStarted(_ result: WorktreeMergeStartedPlugin.Result) {
        logDebug("worktree.merge_started \(result.sourceBranch) → \(result.targetBranch)")
    }

    func handleWorktreeConflictDetected(_ result: WorktreeConflictDetectedPlugin.Result) {
        // Unified conflict banner — origin disambiguates between merge,
        // rebase, and stash-pop conflict contexts; the resolver sheet
        // adapts copy and abort semantics based on the origin.
        guard let banner = ConflictBanner(
            sourceBranch: result.sourceBranch,
            targetBranch: result.targetBranch,
            origin: result.origin,
            paths: result.paths
        ) else {
            logWarning("worktree.conflict_detected unknown origin '\(result.origin)'; dropping")
            return
        }
        gitWorkflowState.conflictBanner = banner
    }

    func handleWorktreeConflictResolved(_ result: WorktreeConflictResolvedPlugin.Result) {
        // Each resolution ticks down the banner's path count; drop the
        // banner when nothing remains.
        if let banner = gitWorkflowState.conflictBanner {
            let remainingPaths = banner.paths.filter { $0 != result.path }
            if result.remaining == 0 || remainingPaths.isEmpty {
                gitWorkflowState.conflictBanner = nil
            } else {
                gitWorkflowState.conflictBanner = ConflictBanner(
                    sourceBranch: banner.sourceBranch,
                    targetBranch: banner.targetBranch,
                    origin: banner.origin,
                    paths: remainingPaths
                )
            }
        }
    }

    func handleWorktreeMergeContinued(_ result: WorktreeMergeContinuedPlugin.Result) {
        // Resolver succeeded — clear banners and refresh status.
        gitWorkflowState.conflictBanner = nil
        gitWorkflowState.pendingMerge = nil
        refreshSourceControlStatus()
    }

    func handleWorktreeMergeAborted(_ result: WorktreeMergeAbortedPlugin.Result) {
        // Abort restores the pre-merge state — clear banners either way.
        gitWorkflowState.conflictBanner = nil
        gitWorkflowState.pendingMerge = nil
        refreshSourceControlStatus()
    }

    func handleWorktreePushed(_ result: WorktreePushedPlugin.Result) {
        // A successful push advances origin — chips are now stale.
        gitWorkflowState.markSourceControlStale()
    }

    func handleWorktreePendingMergeDetected(_ result: WorktreePendingMergeDetectedPlugin.Result) {
        guard let origin = ConflictOrigin(wire: result.origin) else {
            logWarning("worktree.pending_merge_detected unknown origin '\(result.origin)'; dropping")
            return
        }
        gitWorkflowState.pendingMerge = PendingMergeBanner(
            sourceBranch: result.sourceBranch,
            targetBranch: result.targetBranch,
            strategy: result.strategy,
            origin: origin,
            startedAtMs: result.startedAtMs,
            autoAbortAtMs: result.autoAbortAtMs
        )
    }

    func handleWorktreeRebasedOnMain(_ result: WorktreeRebasedOnMainPlugin.Result) {
        // Session branch tip moved to include main. Chips are stale;
        // refresh divergence + worktree status so the UI reflects the
        // new base commit.
        refreshSourceControlStatus()
    }

    func handleWorktreePostRebaseStashConflict(_ result: WorktreePostRebaseStashConflictPlugin.Result) {
        // The `conflict_detected(origin = stash_pop)` event emitted by the
        // server (via `handle_post_stash_pop`) already populates
        // `conflictBanner`. This handler is informational: log the stash
        // ref for diagnostics. Do not set a separate banner — all conflict
        // surfacing flows through `conflictBanner` for UX consistency.
        logDebug("worktree.post_rebase_stash_conflict stash=\(result.stashRef) paths=\(result.paths.count)")
    }

    private func refreshSourceControlStatus() {
        gitWorkflowState.markSourceControlStale()
        Task { await requestWorktreeStatus() }
    }
}
