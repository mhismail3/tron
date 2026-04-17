import Foundation

// MARK: - git.listLocalBranches

struct GitListLocalBranchesParams: Encodable {
    let sessionId: String
}

struct GitListLocalBranchesResult: Decodable {
    let branches: [String]
    let current: String?
}

// MARK: - git.syncMain

/// Params for `git.syncMain` — fast-forward local `main` from its upstream.
struct GitSyncMainParams: Encodable {
    let sessionId: String
    /// Override the auto-detected main/master branch.
    let targetBranch: String?
    /// Remote name (defaults to `origin` on the server).
    let remote: String?
    /// Fetch timeout in milliseconds.
    let fetchTimeoutMs: UInt64?

    init(
        sessionId: String,
        targetBranch: String? = nil,
        remote: String? = nil,
        fetchTimeoutMs: UInt64? = nil
    ) {
        self.sessionId = sessionId
        self.targetBranch = targetBranch
        self.remote = remote
        self.fetchTimeoutMs = fetchTimeoutMs
    }
}

/// Reason the sync was blocked. Mirrors `SyncBlockReason`.
enum GitSyncBlockReason: Equatable {
    case noRemote
    case dirtyWorkingTree
    case localAhead(ahead: UInt64)
    case diverged(ahead: UInt64, behind: UInt64)
    case emptyRepository
    case detachedHead
    case noDefaultBranch
    case notOnDefaultBranch(current: String, expected: String)
    case remoteError(message: String)
    case unknown(raw: String)
}

/// Outcome of `git.syncMain`.
///
/// Wire format: `{outcome: "upToDate"|"fastForwarded"|"blocked", ...}`.
/// The server flattens `reason`/`ahead`/`behind`/`message` directly onto
/// the envelope — we decode manually to preserve that shape.
enum GitSyncOutcome: Decodable, Equatable {
    case upToDate(head: String)
    case fastForwarded(oldHead: String, newHead: String, advancedBy: UInt64)
    case blocked(reason: GitSyncBlockReason)

    private enum CodingKeys: String, CodingKey {
        case outcome, head, oldHead, newHead, advancedBy
        case reason, ahead, behind, message, current, expected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try c.decode(String.self, forKey: .outcome)
        switch outcome {
        case "upToDate":
            self = .upToDate(head: try c.decode(String.self, forKey: .head))
        case "fastForwarded":
            self = .fastForwarded(
                oldHead: try c.decode(String.self, forKey: .oldHead),
                newHead: try c.decode(String.self, forKey: .newHead),
                advancedBy: try c.decode(UInt64.self, forKey: .advancedBy)
            )
        case "blocked":
            let reasonKey = try c.decode(String.self, forKey: .reason)
            let reason: GitSyncBlockReason
            switch reasonKey {
            case "noRemote": reason = .noRemote
            case "dirtyWorkingTree": reason = .dirtyWorkingTree
            case "localAhead":
                reason = .localAhead(
                    ahead: try c.decode(UInt64.self, forKey: .ahead)
                )
            case "diverged":
                reason = .diverged(
                    ahead: try c.decode(UInt64.self, forKey: .ahead),
                    behind: try c.decode(UInt64.self, forKey: .behind)
                )
            case "emptyRepository": reason = .emptyRepository
            case "detachedHead": reason = .detachedHead
            case "noDefaultBranch": reason = .noDefaultBranch
            case "notOnDefaultBranch":
                reason = .notOnDefaultBranch(
                    current: try c.decode(String.self, forKey: .current),
                    expected: try c.decode(String.self, forKey: .expected)
                )
            case "remoteError":
                reason = .remoteError(
                    message: try c.decode(String.self, forKey: .message)
                )
            default:
                reason = .unknown(raw: reasonKey)
            }
            self = .blocked(reason: reason)
        default:
            self = .blocked(reason: .unknown(raw: outcome))
        }
    }
}

// MARK: - git.push

/// Params for `git.push`.
///
/// Protected branches require `overrideProtected == true`; without it,
/// pushes to `main`/`master`/`develop` are rejected server-side even with
/// `forceWithLease`.
struct GitPushParams: Encodable {
    let sessionId: String
    /// Branch to push; defaults to the session's current branch server-side.
    let branch: String?
    let remote: String?
    let forceWithLease: Bool?
    let setUpstream: Bool?
    let dryRun: Bool?
    let overrideProtected: Bool?
    let protectedBranches: [String]?

    init(
        sessionId: String,
        branch: String? = nil,
        remote: String? = nil,
        forceWithLease: Bool? = nil,
        setUpstream: Bool? = nil,
        dryRun: Bool? = nil,
        overrideProtected: Bool? = nil,
        protectedBranches: [String]? = nil
    ) {
        self.sessionId = sessionId
        self.branch = branch
        self.remote = remote
        self.forceWithLease = forceWithLease
        self.setUpstream = setUpstream
        self.dryRun = dryRun
        self.overrideProtected = overrideProtected
        self.protectedBranches = protectedBranches
    }
}

struct GitPushResult: Decodable {
    let success: Bool
    let branch: String
    let remote: String
    let setUpstream: Bool
    let dryRun: Bool
    /// Raw `git` stderr for display when server-side decisions aren't
    /// machine-readable (auth errors, non-FF rejections, hook output).
    let stderr: String?
}
