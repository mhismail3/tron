import Foundation

// MARK: - repo.listSessions

struct RepoListSessionsParams: Encodable {
    let sessionId: String
}

/// Sibling session sharing the same `repoRoot`.
///
/// Used to drive the Repo Sessions sub-sheet in iOS. `commitCount` is
/// commits ahead of the session's `baseBranch`; `baseBehind` is commits
/// the session's base branch has advanced beyond the session branch
/// (drives the "diverged" chip). `hasConflicts` reflects any in-flight
/// merge with unresolved files.
struct RepoSessionSummary: Decodable, Identifiable, Equatable {
    let sessionId: String
    let branch: String
    let baseBranch: String?
    let repoRoot: String
    let commitCount: UInt64
    let baseBehind: UInt64
    let hasConflicts: Bool

    var id: String { sessionId }

    private enum CodingKeys: String, CodingKey {
        case sessionId, branch, baseBranch, repoRoot
        case commitCount, baseBehind, hasConflicts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        branch = try c.decode(String.self, forKey: .branch)
        baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch)
        repoRoot = try c.decode(String.self, forKey: .repoRoot)
        commitCount = try c.decode(UInt64.self, forKey: .commitCount)
        baseBehind = (try? c.decodeIfPresent(UInt64.self, forKey: .baseBehind)) ?? 0
        hasConflicts = try c.decode(Bool.self, forKey: .hasConflicts)
    }
}

struct RepoListSessionsResult: Decodable {
    let sessions: [RepoSessionSummary]
}

// MARK: - repo.getDivergence

struct RepoGetDivergenceParams: Encodable {
    let sessionId: String
}

/// Divergence chips for the Source Control sheet header.
///
/// - `*Main`  — session branch vs local `main`. `nil` if `main` itself
///   doesn't resolve (fresh empty repo, renamed default, detached HEAD).
/// - `*Origin` — local `main` vs `origin/main`. `nil` when no `origin`
///   remote is configured or the remote ref hasn't been fetched. The
///   separate `hasOrigin` flag lets UI distinguish "not applicable" from
///   "genuinely synced at 0/0".
struct RepoDivergence: Decodable, Equatable {
    let aheadMain: UInt64?
    let behindMain: UInt64?
    let aheadOrigin: UInt64?
    let behindOrigin: UInt64?
    let hasOrigin: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.aheadMain = try c.decodeIfPresent(UInt64.self, forKey: .aheadMain)
        self.behindMain = try c.decodeIfPresent(UInt64.self, forKey: .behindMain)
        self.aheadOrigin = try c.decodeIfPresent(UInt64.self, forKey: .aheadOrigin)
        self.behindOrigin = try c.decodeIfPresent(UInt64.self, forKey: .behindOrigin)
        // Older servers didn't send `hasOrigin`; fall back to "present ⇒ true".
        self.hasOrigin = try c.decodeIfPresent(Bool.self, forKey: .hasOrigin)
            ?? (self.aheadOrigin != nil || self.behindOrigin != nil)
    }

    private enum CodingKeys: String, CodingKey {
        case aheadMain, behindMain, aheadOrigin, behindOrigin, hasOrigin
    }
}
