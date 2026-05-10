import Foundation

/// Client for cross-worktree git operations (`git.syncMain`, `git.push`).
///
/// These sit logically outside a single session's worktree — `syncMain` is
/// serialized per-repo on the server; `push` operates on the session
/// branch but respects the server's protected-branch list.
final class GitClient: EngineDomainClient {

    /// Fast-forward local `main` from its upstream. Idempotent when
    /// already up-to-date. Blocks (no rollback) on divergence/dirty tree.
    func syncMain(
        sessionId: String,
        targetBranch: String? = nil,
        remote: String? = nil,
        fetchTimeoutMs: UInt64? = nil,
        prune: Bool? = nil,
        dryRun: Bool? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> GitSyncOutcome {
        _ = try requireTransport().requireConnection()
        let params = GitSyncMainParams(
            sessionId: sessionId,
            targetBranch: targetBranch,
            remote: remote,
            fetchTimeoutMs: fetchTimeoutMs,
            prune: prune,
            dryRun: dryRun
        )
        return try await invokeWrite(
            "git::sync_main",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    /// List every local branch in the session's repo (mainline first,
    /// `session/*` last). Drives the target-branch picker UI.
    func listLocalBranches(sessionId: String) async throws -> GitListLocalBranchesResult {
        _ = try requireTransport().requireConnection()
        let params = GitListLocalBranchesParams(sessionId: sessionId)
        return try await invokeRead("git::list_local_branches", params)
    }

    /// List branches published on the session's remote (default `origin`).
    /// Drives the Merge Changes target picker so only shared branches appear
    /// as merge targets.
    func listRemoteBranches(
        sessionId: String,
        remote: String? = nil
    ) async throws -> GitListRemoteBranchesResult {
        _ = try requireTransport().requireConnection()
        let params = GitListRemoteBranchesParams(sessionId: sessionId, remote: remote)
        return try await invokeRead("git::list_remote_branches", params)
    }

    /// Push a session branch to its remote. Protected branches require
    /// `overrideProtected == true`.
    func push(
        sessionId: String,
        branch: String? = nil,
        remote: String? = nil,
        forceWithLease: Bool? = nil,
        setUpstream: Bool? = nil,
        dryRun: Bool? = nil,
        overrideProtected: Bool? = nil,
        protectedBranches: [String]? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> GitPushResult {
        _ = try requireTransport().requireConnection()
        let params = GitPushParams(
            sessionId: sessionId,
            branch: branch,
            remote: remote,
            forceWithLease: forceWithLease,
            setUpstream: setUpstream,
            dryRun: dryRun,
            overrideProtected: overrideProtected,
            protectedBranches: protectedBranches
        )
        return try await invokeWrite(
            "git::push",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }
}
