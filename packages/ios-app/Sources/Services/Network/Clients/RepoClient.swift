import Foundation

/// Client for repo-scoped queries spanning sibling sessions.
///
/// Drives the Source Control sheet's Repo Sessions sub-sheet and the
/// divergence chips in the status header.
final class RepoClient: EngineDomainClient {

    /// List all active sessions sharing this session's repo root.
    ///
    /// Returns metadata only — the caller jumps via existing session-open
    /// flows; this engine protocol does not mutate other sessions.
    func listSessions(sessionId: String) async throws -> [RepoSessionSummary] {
        _ = try requireTransport().requireConnection()
        let params = RepoListSessionsParams(sessionId: sessionId)
        let result: RepoListSessionsResult = try await invokeRead(
            "repo::list_sessions",
            params
        )
        return result.sessions
    }

    /// Get the four divergence counts (ahead/behind main, ahead/behind origin).
    func getDivergence(sessionId: String) async throws -> RepoDivergence {
        _ = try requireTransport().requireConnection()
        let params = RepoGetDivergenceParams(sessionId: sessionId)
        return try await invokeRead("repo::get_divergence", params)
    }
}
