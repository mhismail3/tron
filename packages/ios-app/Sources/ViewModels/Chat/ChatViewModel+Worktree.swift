import Foundation

// MARK: - Worktree RPC Methods

extension ChatViewModel {

    /// Request worktree status from server (fire-and-forget, swallows errors)
    func requestWorktreeStatus() async {
        worktreeState.isLoading = true
        defer { worktreeState.isLoading = false }

        do {
            let result = try await rpcClient.misc.getWorktreeStatus(sessionId: sessionId)
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
            let result = try await rpcClient.misc.commitWorktree(
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

    /// Merge the session's worktree branch into a target branch
    func mergeWorktree(targetBranch: String, strategy: String? = nil) async {
        worktreeState.isLoading = true
        defer { worktreeState.isLoading = false }

        do {
            let result = try await rpcClient.misc.mergeWorktree(
                sessionId: sessionId,
                targetBranch: targetBranch,
                strategy: strategy
            )
            if !result.success {
                if let conflicts = result.conflicts, !conflicts.isEmpty {
                    showErrorAlert("Merge conflicts in: \(conflicts.joined(separator: ", "))")
                } else if let error = result.error {
                    showErrorAlert(error)
                }
            }
            // Refresh status after merge attempt
            await requestWorktreeStatus()
        } catch {
            showErrorAlert("Merge failed: \(error.localizedDescription)")
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
        // Increment commit count and clear uncommitted flag
        if let info = worktreeState.status?.worktree {
            let newCount = (info.commitCount ?? 0) + 1
            worktreeState.status = WorktreeGetStatusResult(
                hasWorktree: true,
                worktree: WorktreeInfo(
                    isolated: info.isolated,
                    branch: info.branch,
                    baseCommit: info.baseCommit,
                    path: info.path,
                    baseBranch: info.baseBranch,
                    repoRoot: info.repoRoot,
                    hasUncommittedChanges: false,
                    commitCount: newCount,
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
}
