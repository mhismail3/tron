import Foundation

/// Client for worktree-related RPC methods.
/// Handles worktree status, commits, merges, diffs, and branch management.
@MainActor
final class WorktreeClient {
    private unowned let transport: RPCTransport

    init(transport: RPCTransport) {
        self.transport = transport
    }

    // MARK: - Status

    /// Get worktree status for a session
    func getStatus(sessionId: String) async throws -> WorktreeGetStatusResult {
        let ws = try transport.requireConnection()

        let params = WorktreeGetStatusParams(sessionId: sessionId)
        return try await ws.send(method: "worktree.getStatus", params: params)
    }

    // MARK: - Commit & Merge

    /// Commit changes in a session's worktree
    func commit(sessionId: String, message: String) async throws -> WorktreeCommitResult {
        let ws = try transport.requireConnection()

        let params = WorktreeCommitParams(sessionId: sessionId, message: message)
        let result: WorktreeCommitResult = try await ws.send(method: "worktree.commit", params: params)

        if result.success {
            logger.info("Committed worktree changes: \(result.commitHash ?? "unknown")", category: .session)
        }

        return result
    }

    /// Merge a session's worktree to a target branch
    func merge(
        sessionId: String,
        targetBranch: String,
        strategy: String? = nil
    ) async throws -> WorktreeMergeResult {
        let ws = try transport.requireConnection()

        let params = WorktreeMergeParams(
            sessionId: sessionId,
            targetBranch: targetBranch,
            strategy: strategy
        )
        let result: WorktreeMergeResult = try await ws.send(method: "worktree.merge", params: params)

        if result.success {
            logger.info("Merged worktree to \(targetBranch): \(result.mergeCommit ?? "unknown")", category: .session)
        }

        return result
    }

    // MARK: - Branches

    /// List all session branches (active and preserved) for the session's repo
    func listSessionBranches(sessionId: String) async throws -> [SessionBranchInfo] {
        let ws = try transport.requireConnection()
        let params = ListSessionBranchesParams(sessionId: sessionId)
        let result: SessionBranchListResult = try await ws.send(
            method: "worktree.listSessionBranches",
            params: params
        )
        return result.branches
    }

    /// Delete a single session branch
    func deleteBranch(sessionId: String, branch: String) async throws -> DeleteBranchResult {
        let ws = try transport.requireConnection()
        let params = DeleteBranchParams(sessionId: sessionId, branch: branch)
        return try await ws.send(method: "worktree.deleteBranch", params: params)
    }

    /// Prune all inactive session branches
    func pruneBranches(sessionId: String) async throws -> PruneBranchesResult {
        let ws = try transport.requireConnection()
        let params = PruneBranchesParams(sessionId: sessionId)
        return try await ws.send(method: "worktree.pruneBranches", params: params)
    }

    // MARK: - Diffs

    /// Get committed diff (base..HEAD) for a session
    func getCommittedDiff(sessionId: String) async throws -> CommittedDiffResult {
        let ws = try transport.requireConnection()
        let params = GetCommittedDiffParams(sessionId: sessionId)
        return try await ws.send(
            method: "worktree.getCommittedDiff",
            params: params
        )
    }

    /// Get diff of all uncommitted changes for a session's working directory
    func getWorkingDirectoryDiff(sessionId: String) async throws -> WorktreeGetDiffResult {
        let ws = try transport.requireConnection()
        let params = WorktreeGetDiffParams(sessionId: sessionId)
        return try await ws.send(method: "worktree.getDiff", params: params)
    }
}
