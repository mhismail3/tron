import Foundation

// MARK: - Worktree RPC Methods

extension ChatViewModel {

    /// Request worktree status from server (fire-and-forget, swallows errors)
    func requestWorktreeStatus() async {
        worktreeState.isLoading = true
        defer { worktreeState.isLoading = false }

        do {
            let result = try await rpcClient.worktree.getStatus(sessionId: sessionId)
            worktreeState.status = result
        } catch {
            // Swallow — worktree status is non-critical
            logDebug("Worktree status request failed: \(error)")
        }
    }

    /// Commit changes in the session's worktree
    func commitWorktreeChanges(message: String) async {
        worktreeState.isLoading = true
        defer { worktreeState.isLoading = false }

        do {
            let result = try await rpcClient.worktree.commit(
                sessionId: sessionId,
                message: message
            )
            if result.success {
                // Refresh status to reflect new commit count and cleared uncommitted changes
                await requestWorktreeStatus()
            } else if let error = result.error {
                showErrorAlert(error)
            }
        } catch {
            showErrorAlert("Commit failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Real-time WebSocket Event Handlers

    func handleWorktreeAcquired(_ result: WorktreeAcquiredPlugin.Result) {
        worktreeState.status = WorktreeGetStatusResult(
            hasWorktree: true,
            worktree: WorktreeInfo(
                isolated: true,
                branch: result.branch,
                baseCommit: result.baseCommit,
                path: result.path,
                baseBranch: result.baseBranch,
                repoRoot: nil,
                hasUncommittedChanges: false,
                commitCount: 0,
                isMerged: false
            )
        )
    }

    func handleWorktreeCommit(_ result: WorktreeCommitPlugin.Result) {
        // Use server-authoritative commit count and dirty flag
        if let info = worktreeState.status?.worktree {
            worktreeState.status = WorktreeGetStatusResult(
                hasWorktree: true,
                worktree: WorktreeInfo(
                    isolated: info.isolated,
                    branch: info.branch,
                    baseCommit: info.baseCommit,
                    path: info.path,
                    baseBranch: info.baseBranch,
                    repoRoot: info.repoRoot,
                    hasUncommittedChanges: result.hasUncommittedChanges,
                    commitCount: result.totalCommitCount,
                    isMerged: false
                )
            )
        }
    }

    func handleWorktreeMerged(_ result: WorktreeMergedPlugin.Result) {
        // Refresh status after merge — the server state has changed
        Task { await requestWorktreeStatus() }
    }

    func handleWorktreeReleased(_ result: WorktreeReleasedPlugin.Result) {
        worktreeState.status = WorktreeGetStatusResult(
            hasWorktree: false,
            worktree: nil
        )
    }

    // MARK: - Git Workflow Event Handlers

    func handleWorktreeMainSynced(_ result: WorktreeMainSyncedPlugin.Result) {
        // Divergence chips in SourceControlStatusHeader are recomputed on sheet
        // reload; nothing to mutate in ChatViewModel state.
        logDebug("worktree.main_synced advancedBy=\(result.advancedBy)")
    }

    func handleWorktreeSessionFinalized(_ result: WorktreeSessionFinalizedPlugin.Result) {
        // Rebranch occurred — refresh worktree status to pick up new branch/base.
        Task { await requestWorktreeStatus() }
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
        gitWorkflowState.conflictBanner = ConflictBanner(
            sourceBranch: result.sourceBranch,
            targetBranch: result.targetBranch,
            paths: result.paths
        )
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
                    paths: remainingPaths
                )
            }
        }
    }

    func handleWorktreeMergeContinued(_ result: WorktreeMergeContinuedPlugin.Result) {
        // Resolver succeeded — clear banners and refresh status.
        gitWorkflowState.conflictBanner = nil
        gitWorkflowState.pendingMerge = nil
        Task { await requestWorktreeStatus() }
    }

    func handleWorktreeMergeAborted(_ result: WorktreeMergeAbortedPlugin.Result) {
        // Abort restores the pre-merge state — clear banners either way.
        gitWorkflowState.conflictBanner = nil
        gitWorkflowState.pendingMerge = nil
        Task { await requestWorktreeStatus() }
    }

    func handleWorktreePushed(_ result: WorktreePushedPlugin.Result) {
        // A successful push advances origin — chips are now stale.
        gitWorkflowState.markDivergenceStale()
    }

    func handleWorktreePendingMergeDetected(_ result: WorktreePendingMergeDetectedPlugin.Result) {
        gitWorkflowState.pendingMerge = PendingMergeBanner(
            sourceBranch: result.sourceBranch,
            targetBranch: result.targetBranch,
            strategy: result.strategy,
            startedAtMs: result.startedAtMs,
            autoAbortAtMs: result.autoAbortAtMs
        )
    }
}
