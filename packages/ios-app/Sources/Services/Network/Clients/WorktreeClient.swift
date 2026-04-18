import Foundation

/// Client for worktree-related RPC methods.
/// Handles worktree status, commits, finalize, diffs, conflict state, and branch management.
final class WorktreeClient: RPCDomainClient {

    // MARK: - Status

    /// Get worktree status for a session
    func getStatus(sessionId: String) async throws -> WorktreeGetStatusResult {
        let ws = try requireTransport().requireConnection()

        let params = WorktreeGetStatusParams(sessionId: sessionId)
        return try await ws.send(method: "worktree.getStatus", params: params)
    }

    // MARK: - Commit

    /// Commit changes in a session's worktree.
    ///
    /// All flags are optional. When omitted the server applies its
    /// defaults: `stageAll = true` (runs `git add -A` first), `amend =
    /// false`, `signoff = false`. Callers should pass `nil` rather than
    /// `false` when they have no opinion — this lets the server's default
    /// stay authoritative.
    func commit(
        sessionId: String,
        message: String,
        amend: Bool? = nil,
        signoff: Bool? = nil,
        stageAll: Bool? = nil
    ) async throws -> WorktreeCommitResult {
        let ws = try requireTransport().requireConnection()

        let params = WorktreeCommitParams(
            sessionId: sessionId,
            message: message,
            amend: amend,
            signoff: signoff,
            stageAll: stageAll
        )
        let result: WorktreeCommitResult = try await ws.send(method: "worktree.commit", params: params)

        if result.success {
            logger.info("Committed worktree changes: \(result.commitHash ?? "unknown")", category: .session)
        }

        return result
    }

    // MARK: - Branches

    /// List all session branches (active and preserved) for the session's repo
    func listSessionBranches(sessionId: String) async throws -> [SessionBranchInfo] {
        let ws = try requireTransport().requireConnection()
        let params = ListSessionBranchesParams(sessionId: sessionId)
        let result: SessionBranchListResult = try await ws.send(
            method: "worktree.listSessionBranches",
            params: params
        )
        return result.branches
    }

    /// Delete a single session branch
    func deleteBranch(sessionId: String, branch: String) async throws -> DeleteBranchResult {
        let ws = try requireTransport().requireConnection()
        let params = DeleteBranchParams(sessionId: sessionId, branch: branch)
        return try await ws.send(method: "worktree.deleteBranch", params: params)
    }

    /// Prune all inactive session branches
    func pruneBranches(sessionId: String) async throws -> PruneBranchesResult {
        let ws = try requireTransport().requireConnection()
        let params = PruneBranchesParams(sessionId: sessionId)
        return try await ws.send(method: "worktree.pruneBranches", params: params)
    }

    // MARK: - Diffs

    /// Get committed diff (base..HEAD) for a session
    func getCommittedDiff(sessionId: String) async throws -> CommittedDiffResult {
        let ws = try requireTransport().requireConnection()
        let params = GetCommittedDiffParams(sessionId: sessionId)
        return try await ws.send(
            method: "worktree.getCommittedDiff",
            params: params
        )
    }

    /// Get diff of all uncommitted changes for a session's working directory
    func getWorkingDirectoryDiff(sessionId: String) async throws -> WorktreeGetDiffResult {
        let ws = try requireTransport().requireConnection()
        let params = WorktreeGetDiffParams(sessionId: sessionId)
        return try await ws.send(method: "worktree.getDiff", params: params)
    }

    // MARK: - Stage / Unstage / Discard

    /// Stage files in the working directory
    func stageFiles(sessionId: String, paths: [String]) async throws -> WorktreeFileOperationResult {
        let ws = try requireTransport().requireConnection()
        let params = WorktreeStageFilesParams(sessionId: sessionId, paths: paths)
        return try await ws.send(method: "worktree.stageFiles", params: params)
    }

    /// Unstage files from the index
    func unstageFiles(sessionId: String, paths: [String]) async throws -> WorktreeFileOperationResult {
        let ws = try requireTransport().requireConnection()
        let params = WorktreeUnstageFilesParams(sessionId: sessionId, paths: paths)
        return try await ws.send(method: "worktree.unstageFiles", params: params)
    }

    /// Discard file changes (tracked: restore from HEAD, untracked: delete)
    func discardFiles(sessionId: String, paths: [String]) async throws -> WorktreeFileOperationResult {
        let ws = try requireTransport().requireConnection()
        let params = WorktreeDiscardFilesParams(sessionId: sessionId, paths: paths)
        return try await ws.send(method: "worktree.discardFiles", params: params)
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
        rebranch: Bool? = nil
    ) async throws -> WorktreeFinalizeSessionResult {
        let ws = try requireTransport().requireConnection()
        let params = WorktreeFinalizeSessionParams(
            sessionId: sessionId,
            sourceBranch: sourceBranch,
            targetBranch: targetBranch,
            strategy: strategy,
            newBranchName: newBranchName,
            preserveOld: preserveOld,
            rebranch: rebranch
        )
        return try await ws.send(method: "worktree.finalizeSession", params: params)
    }

    /// Probe current conflicts from `.git/MERGE_HEAD`. Idempotent — safe to
    /// call at any time; returns an empty array if no merge is in-flight.
    func listConflicts(sessionId: String) async throws -> [ConflictedFile] {
        let ws = try requireTransport().requireConnection()
        let params = WorktreeListConflictsParams(sessionId: sessionId)
        let result: WorktreeListConflictsResult = try await ws.send(
            method: "worktree.listConflicts",
            params: params
        )
        return result.conflicts
    }

    /// Abort the merge, restoring pre-merge working tree state.
    func abortMerge(
        sessionId: String,
        reason: String? = nil
    ) async throws -> WorktreeAbortMergeResult {
        let ws = try requireTransport().requireConnection()
        let params = WorktreeAbortMergeParams(sessionId: sessionId, reason: reason)
        return try await ws.send(method: "worktree.abortMerge", params: params)
    }

    /// Spawn the `conflict-resolver` subagent to drive resolution.
    ///
    /// On success, `subagentSessionId` identifies the child session whose
    /// chat stream the UI can embed live. `spawned == false` indicates a
    /// configuration issue (no subagent manager on the server) — the UI
    /// should degrade gracefully to manual resolution.
    func resolveConflictsWithSubagent(sessionId: String) async throws -> WorktreeResolveWithSubagentResult {
        let ws = try requireTransport().requireConnection()
        let params = WorktreeResolveWithSubagentParams(sessionId: sessionId)
        return try await ws.send(
            method: "worktree.resolveConflictsWithSubagent",
            params: params
        )
    }
}
