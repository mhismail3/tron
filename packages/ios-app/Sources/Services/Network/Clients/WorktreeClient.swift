import Foundation

/// Client for worktree-related engine capabilities.
/// Handles worktree status, commits, finalize, diffs, conflict state, and branch management.
final class WorktreeClient: EngineDomainClient {

    // MARK: - Status

    /// Get worktree status for a session
    func getStatus(sessionId: String) async throws -> WorktreeGetStatusResult {
        _ = try requireTransport().requireConnection()

        let params = WorktreeGetStatusParams(sessionId: sessionId)
        return try await invokeRead("worktree::get_status", params)
    }

    /// Quick check: is the given absolute path inside a git repository?
    /// Used by the New Session sheet to decide whether to surface the
    /// per-session worktree-isolation toggle.
    func isGitRepo(_ path: String) async throws -> Bool {
        _ = try requireTransport().requireConnection()
        let params = WorktreeIsGitRepoParams(path: path)
        let result: WorktreeIsGitRepoResult = try await invokeRead(
            "worktree::is_git_repo",
            params
        )
        return result.isGitRepo
    }

    // MARK: - Commit

    /// Commit changes in a session's worktree.
    ///
    /// `stageAll` is required — the caller must decide between
    /// "stage everything first" (`true`, equivalent to `git add -A`) and
    /// "commit only what's already indexed" (`false`). `amend` and
    /// `signoff` remain optional opt-in flags; omit them when the call
    /// site has no opinion.
    func commit(
        sessionId: String,
        message: String,
        stageAll: Bool,
        amend: Bool? = nil,
        signoff: Bool? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorktreeCommitResult {
        _ = try requireTransport().requireConnection()

        let params = WorktreeCommitParams(
            sessionId: sessionId,
            message: message,
            stageAll: stageAll,
            amend: amend,
            signoff: signoff
        )
        let result: WorktreeCommitResult = try await invokeWrite(
            "worktree::commit",
            params,
            idempotencyKey: idempotencyKey
        )
        logger.info("Committed worktree changes: \(result.commitHash ?? "nothing-to-commit")", category: .session)
        return result
    }

    // MARK: - Branches

    /// List all session branches (active and preserved) for the session's repo
    func listSessionBranches(sessionId: String) async throws -> [SessionBranchInfo] {
        _ = try requireTransport().requireConnection()
        let params = ListSessionBranchesParams(sessionId: sessionId)
        let result: SessionBranchListResult = try await invokeRead(
            "worktree::list_session_branches",
            params
        )
        return result.branches
    }

    /// Delete a single session branch
    func deleteBranch(sessionId: String, branch: String, idempotencyKey: EngineIdempotencyKey) async throws -> DeleteBranchResult {
        _ = try requireTransport().requireConnection()
        let params = DeleteBranchParams(sessionId: sessionId, branch: branch)
        return try await invokeWrite("worktree::delete_branch", params, idempotencyKey: idempotencyKey)
    }

    /// Prune all inactive session branches
    func pruneBranches(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws -> PruneBranchesResult {
        _ = try requireTransport().requireConnection()
        let params = PruneBranchesParams(sessionId: sessionId)
        return try await invokeWrite("worktree::prune_branches", params, idempotencyKey: idempotencyKey)
    }

    // MARK: - Diffs

    /// Get committed diff (base..HEAD) for a session
    func getCommittedDiff(sessionId: String) async throws -> CommittedDiffResult {
        _ = try requireTransport().requireConnection()
        let params = GetCommittedDiffParams(sessionId: sessionId)
        return try await invokeRead(
            "worktree::get_committed_diff",
            params
        )
    }

    /// Get diff of all uncommitted changes for a session's working directory
    func getWorkingDirectoryDiff(sessionId: String) async throws -> WorktreeGetDiffResult {
        _ = try requireTransport().requireConnection()
        let params = WorktreeGetDiffParams(sessionId: sessionId)
        return try await invokeRead("worktree::get_diff", params)
    }

    // MARK: - Stage / Unstage / Discard

    /// Stage files in the working directory
    func stageFiles(sessionId: String, paths: [String], idempotencyKey: EngineIdempotencyKey) async throws -> WorktreeFileOperationResult {
        _ = try requireTransport().requireConnection()
        let params = WorktreeStageFilesParams(sessionId: sessionId, paths: paths)
        return try await invokeWrite("worktree::stage_files", params, idempotencyKey: idempotencyKey)
    }

    /// Unstage files from the index
    func unstageFiles(sessionId: String, paths: [String], idempotencyKey: EngineIdempotencyKey) async throws -> WorktreeFileOperationResult {
        _ = try requireTransport().requireConnection()
        let params = WorktreeUnstageFilesParams(sessionId: sessionId, paths: paths)
        return try await invokeWrite("worktree::unstage_files", params, idempotencyKey: idempotencyKey)
    }

    /// Discard file changes (tracked: restore from HEAD, untracked: delete)
    func discardFiles(sessionId: String, paths: [String], idempotencyKey: EngineIdempotencyKey) async throws -> WorktreeFileOperationResult {
        _ = try requireTransport().requireConnection()
        let params = WorktreeDiscardFilesParams(sessionId: sessionId, paths: paths)
        return try await invokeWrite("worktree::discard_files", params, idempotencyKey: idempotencyKey)
    }

    // MARK: - Git Workflow Suite

    /// Finalize a session: merge into `targetBranch`, then open a fresh
    /// session-follow-up branch for continued work. On conflict returns a
    /// two-shape response — callers must check `.conflicts == true`.
    func finalizeSession(
        sessionId: String,
        sourceBranch: String? = nil,
        targetBranch: String? = nil,
        strategy: String? = nil,
        newBranchName: String? = nil,
        preserveOld: Bool? = nil,
        rebranch: Bool? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorktreeFinalizeSessionResult {
        _ = try requireTransport().requireConnection()
        let params = WorktreeFinalizeSessionParams(
            sessionId: sessionId,
            sourceBranch: sourceBranch,
            targetBranch: targetBranch,
            strategy: strategy,
            newBranchName: newBranchName,
            preserveOld: preserveOld,
            rebranch: rebranch
        )
        return try await invokeWrite("worktree::finalize_session", params, idempotencyKey: idempotencyKey)
    }

    /// Rebase-on-main: pull main's commits forward into the session's
    /// branch. Strategy is `"rebase"` (default, linear) or `"merge"`
    /// (creates a merge commit on the session branch). `"squash"` is
    /// rejected server-side as INVALID_PARAMS.
    ///
    /// Result is a tagged enum — callers pattern-match:
    /// - `.success` — clean or post-conflict-resolution completion
    /// - `.conflicts` — user must run the conflict state machine
    ///   (`listConflicts` → `resolveConflict` → `continueMerge`)
    /// - `.noOp` — session was already up-to-date with main
    func rebaseOnMain(
        sessionId: String,
        mainBranch: String? = nil,
        strategy: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorktreeRebaseOnMainResult {
        _ = try requireTransport().requireConnection()
        let params = WorktreeRebaseOnMainParams(
            sessionId: sessionId,
            mainBranch: mainBranch,
            strategy: strategy
        )
        return try await invokeWrite("worktree::rebase_on_main", params, idempotencyKey: idempotencyKey)
    }

    /// Probe current conflicts from `.git/MERGE_HEAD`. Idempotent — safe to
    /// call at any time; returns an empty array if no merge is in-flight.
    func listConflicts(sessionId: String) async throws -> [ConflictedFile] {
        _ = try requireTransport().requireConnection()
        let params = WorktreeListConflictsParams(sessionId: sessionId)
        let result: WorktreeListConflictsResult = try await invokeRead(
            "worktree::list_conflicts",
            params
        )
        return result.conflicts
    }

    /// Abort the merge, restoring pre-merge working tree state.
    func abortMerge(
        sessionId: String,
        reason: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorktreeAbortMergeResult {
        _ = try requireTransport().requireConnection()
        let params = WorktreeAbortMergeParams(sessionId: sessionId, reason: reason)
        return try await invokeWrite("worktree::abort_merge", params, idempotencyKey: idempotencyKey)
    }

    /// Spawn the `conflict-resolver` subagent to drive resolution.
    ///
    /// On success, `subagentSessionId` identifies the child session whose
    /// chat stream the UI can embed live. `spawned == false` indicates a
    /// configuration issue (no subagent manager on the server) — the UI
    /// should degrade gracefully to manual resolution.
    func resolveConflictsWithSubagent(
        sessionId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorktreeResolveWithSubagentResult {
        _ = try requireTransport().requireConnection()
        let params = WorktreeResolveWithSubagentParams(sessionId: sessionId)
        return try await invokeWrite(
            "worktree::resolve_conflicts_with_subagent",
            params,
            idempotencyKey: idempotencyKey
        )
    }
}
