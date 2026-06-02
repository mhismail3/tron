import Foundation

// MARK: - Worktree Methods

/// Worktree information for a session
struct WorktreeInfo: Decodable, Equatable {
    let isolated: Bool
    let branch: String
    let baseCommit: String
    let path: String
    let baseBranch: String?
    let repoRoot: String?
    let hasUncommittedChanges: Bool?
    let commitCount: Int?
    let isMerged: Bool?

    /// Short branch name (removes 'session/' prefix, truncates session IDs)
    var shortBranch: String {
        var name = branch
        if name.hasPrefix("session/") {
            name = String(name.dropFirst(8))
        }
        if name.hasPrefix("sess_") {
            let hexPart = name.dropFirst(5)
            return String(hexPart.prefix(8))
        }
        return name
    }

    /// True when there is no session-specific branch worth chipping in
    /// UI chrome. Covers two cases:
    ///
    /// 1. **Passthrough mode** (`isolated == false`) — the session uses the
    ///    repo root directly rather than its own worktree. This is the state
    ///    a session enters after `worktree.finalizeSession` releases its
    ///    worktree, or when a fresh session starts on `main` without
    ///    isolation. The server returns `baseBranch: null` here; there's no
    ///    distinct branch to highlight even though `branch` is populated.
    /// 2. **Isolated-on-base** (`branch == baseBranch`) — a less common
    ///    state where the isolated worktree happens to sit on the recorded
    ///    base branch.
    ///
    /// Returns false when `isolated == true && baseBranch == nil` — we
    /// cannot prove equality and default to showing the chip conservatively.
    var isOnBaseBranch: Bool {
        if !isolated { return true }
        guard let baseBranch else { return false }
        return branch == baseBranch
    }
}

/// Get worktree status for a session
struct WorktreeGetStatusParams: Encodable {
    let sessionId: String
}

struct WorktreeGetStatusResult: Decodable {
    let hasWorktree: Bool
    let worktree: WorktreeInfo?

    /// True for any git checkout the server can address for this session.
    /// This includes isolated session worktrees and passthrough sessions that
    /// operate directly on the selected repo branch.
    var hasSourceControlCheckout: Bool {
        hasWorktree && worktree != nil
    }

    /// True only for a server-owned session branch/worktree. Branch-finalize,
    /// rebase-on-main, and peer-session workflows require this stronger state.
    var hasIsolatedWorktree: Bool {
        hasWorktree && worktree?.isolated == true
    }

    /// Repo-scoped source-control reads require a server-known checkout and
    /// repository root. Direct-branch sessions can query repo metadata even
    /// though isolated-only mutation flows stay disabled.
    var canQueryRepoMetadata: Bool {
        guard hasSourceControlCheckout else { return false }
        guard let repoRoot = worktree?.repoRoot?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !repoRoot.isEmpty
    }
}

/// Quick check: is the given absolute path a git repository?
struct WorktreeIsGitRepoParams: Encodable {
    let path: String
}

struct WorktreeIsGitRepoResult: Decodable {
    let isGitRepo: Bool
}

/// Commit changes in a session's worktree.
///
/// `stageAll` is a contract-required flag — the caller must explicitly
/// choose "stage everything first" (`true`, equivalent to `git add -A`)
/// or "commit only what's already indexed" (`false`). There is no
/// server-side default. `amend` and `signoff` stay optional: most commits
/// want them off and sending `false` on every wire would be pure overhead.
struct WorktreeCommitParams: Encodable {
    let sessionId: String
    let message: String
    /// When true, pass `--amend` — rewrites HEAD instead of creating a new commit.
    let amend: Bool?
    /// When true, append a `Signed-off-by:` trailer (DCO projects).
    let signoff: Bool?
    /// When true, run `git add -A` before committing so every tracked and
    /// untracked file is included. When false, only the index is committed.
    let stageAll: Bool

    init(
        sessionId: String,
        message: String,
        stageAll: Bool,
        amend: Bool? = nil,
        signoff: Bool? = nil
    ) {
        self.sessionId = sessionId
        self.message = message
        self.amend = amend
        self.signoff = signoff
        self.stageAll = stageAll
    }
}

/// Result of a successful `worktree.commit` call. Failures throw a typed
/// `EngineProtocolError` (see `friendlyGitError`) — there is no `success: false` path.
/// `commitHash == nil` means "nothing to commit" (the working tree was clean).
struct WorktreeCommitResult: Decodable {
    let commitHash: String?
    let filesChanged: [String]?
    /// Total lines inserted across `filesChanged`. Absent when the server
    /// cannot compute the stat (e.g. amending a root commit).
    let insertions: Int?
    /// Total lines deleted across `filesChanged`. Same caveats as `insertions`.
    let deletions: Int?
}

// MARK: - Session Branches

/// Information about a session branch (active or preserved)
struct SessionBranchInfo: Decodable, Identifiable, Hashable {
    let branch: String
    let isActive: Bool
    let sessionId: String?
    let commitCount: Int
    let lastCommitHash: String
    let lastCommitMessage: String
    let lastCommitDate: String
    let baseBranch: String?

    var id: String { branch }

    var shortBranch: String {
        branch.hasPrefix("session/") ? String(branch.dropFirst(8)) : branch
    }
}

struct SessionBranchListResult: Decodable {
    let branches: [SessionBranchInfo]
}

/// Params for listing session branches
struct ListSessionBranchesParams: Encodable {
    let sessionId: String
}

/// Params for getting committed diff
struct GetCommittedDiffParams: Encodable {
    let sessionId: String
}

/// Result of fetching committed changes for a session
struct CommittedDiffResult: Decodable {
    let commits: [CommitEntry]
    let files: [CommittedFileEntry]
    let summary: CommittedDiffSummary
    let truncated: Bool
}

/// A single commit entry
struct CommitEntry: Decodable, Identifiable, Hashable {
    let hash: String
    let message: String
    let date: String

    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }
}

/// Per-file entry in a committed diff
struct CommittedFileEntry: Decodable, Identifiable, Hashable {
    let path: String
    let status: CommittedFileStatus
    let diff: String?
    let additions: Int
    let deletions: Int

    var id: String { path }

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var fileExtension: String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    var fileChangeStatus: FileChangeStatus {
        switch status {
        case .added: return .added
        case .modified: return .modified
        case .deleted: return .deleted
        case .renamed: return .renamed
        case .copied: return .copied
        }
    }
}

enum CommittedFileStatus: String, Decodable, Hashable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
}

/// Aggregate diff summary for committed changes
struct CommittedDiffSummary: Decodable, Hashable {
    let totalFiles: Int
    let totalAdditions: Int
    let totalDeletions: Int
}

// MARK: - Branch Management

/// Params for deleting a single session branch
struct DeleteBranchParams: Encodable {
    let sessionId: String
    let branch: String
}

/// Result of deleting a single session branch
struct DeleteBranchResult: Decodable {
    let branch: String
    let hadUnmergedCommits: Bool
    let unmergedCount: Int
}

/// Params for pruning all inactive session branches
struct PruneBranchesParams: Encodable {
    let sessionId: String
}

/// Result of pruning inactive session branches
struct PruneBranchesResult: Decodable {
    let deleted: [String]
    let failed: [PruneFailure]
}

/// A branch that failed to be pruned
struct PruneFailure: Decodable {
    let branch: String
    let error: String
}

// MARK: - Stage / Unstage / Discard

struct WorktreeStageFilesParams: Encodable {
    let sessionId: String
    let paths: [String]
}

struct WorktreeUnstageFilesParams: Encodable {
    let sessionId: String
    let paths: [String]
}

struct WorktreeDiscardFilesParams: Encodable {
    let sessionId: String
    let paths: [String]
}

struct WorktreeFileOperationResult: Decodable {
    let success: Bool
}

// MARK: - Finalize Session (merge + rebranch)

/// Params for `worktree.finalizeSession`.
///
/// Merges the session's source branch into `targetBranch`, then creates a
/// fresh `newBranchName` for continued work. On conflict, returns
/// `conflicts: true` with a hint to run `startMerge` → resolve → `continueMerge`.
struct WorktreeFinalizeSessionParams: Encodable {
    let sessionId: String
    let sourceBranch: String?
    let targetBranch: String?
    let strategy: String?      // "merge" | "rebase" | "squash"
    let newBranchName: String?
    let preserveOld: Bool?
    /// When false, the worktree stays on its current branch post-merge
    /// (no follow-up branch is created). Defaults to true server-side.
    let rebranch: Bool?

    init(
        sessionId: String,
        sourceBranch: String? = nil,
        targetBranch: String? = nil,
        strategy: String? = nil,
        newBranchName: String? = nil,
        preserveOld: Bool? = nil,
        rebranch: Bool? = nil
    ) {
        self.sessionId = sessionId
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.strategy = strategy
        self.newBranchName = newBranchName
        self.preserveOld = preserveOld
        self.rebranch = rebranch
    }
}

/// Result of `worktree.finalizeSession`.
///
/// Two-shape response: on success every `*` field is populated; on
/// conflict, only `conflicts == true`, `error`, and `hint` are set and the
/// caller must transition to the merge state machine.
struct WorktreeFinalizeSessionResult: Decodable {
    let mergeCommit: String?
    let newBranch: String?
    let newBaseCommit: String?
    let oldBranchDeleted: Bool?
    /// Git error string when deletion was requested but failed.
    let oldBranchDeleteError: String?
    let strategy: String?

    // Conflict branch
    let conflicts: Bool?
    let error: String?
    let hint: String?
}

// MARK: - Rebase on Main

/// Params for `worktree.rebaseOnMain` — pull main forward into the
/// session's branch. Strategy is `"rebase"` (default) or `"merge"`;
/// `"squash"` is rejected with INVALID_PARAMS.
struct WorktreeRebaseOnMainParams: Encodable {
    let sessionId: String
    /// Overrides `info.base_branch` when set. Useful when the session's
    /// base branch got renamed or no longer exists.
    let mainBranch: String?
    let strategy: String?

    init(
        sessionId: String,
        mainBranch: String? = nil,
        strategy: String? = nil
    ) {
        self.sessionId = sessionId
        self.mainBranch = mainBranch
        self.strategy = strategy
    }
}

/// Result of `worktree.rebaseOnMain`. Three-shape tagged enum — the
/// `type` discriminator picks between `success`, `conflicts`, and `noOp`.
/// Each branch carries only the fields relevant to that outcome.
enum WorktreeRebaseOnMainResult: Decodable, Equatable {
    case success(RebaseSuccess)
    case conflicts(RebaseConflicts)
    case noOp(RebaseNoOp)

    struct RebaseSuccess: Decodable, Equatable {
        let oldBaseCommit: String
        let newBaseCommit: String
        let mainCommitsIncorporated: UInt64
        let strategy: String
        let hadAutoStash: Bool
    }

    struct RebaseConflicts: Decodable, Equatable {
        let count: UInt64
        let hint: String?
    }

    struct RebaseNoOp: Decodable, Equatable {
        let ahead: UInt64
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "success":
            self = .success(try RebaseSuccess(from: decoder))
        case "conflicts":
            self = .conflicts(try RebaseConflicts(from: decoder))
        case "noOp":
            self = .noOp(try RebaseNoOp(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown type '\(type)'"
            )
        }
    }
}

// MARK: - Merge State Machine

/// A conflicted file, with optional base64-encoded ours/theirs/base bytes.
/// Binary files surface with `isBinary == true` and byte slabs populated.
struct ConflictedFile: Decodable, Identifiable, Equatable {
    let path: String
    let isBinary: Bool
    /// One of "both_modified" | "both_added" | "deleted_by_us" |
    /// "deleted_by_them" | "rename" | "other".
    let kind: String
    /// base/ours/theirs are base64-encoded — decode lazily so large blobs
    /// aren't materialized eagerly.
    let base: String?
    let ours: String?
    let theirs: String?

    var id: String { path }
}

struct WorktreeListConflictsParams: Encodable {
    let sessionId: String
}

struct WorktreeListConflictsResult: Decodable {
    let conflicts: [ConflictedFile]
}

struct WorktreeAbortMergeParams: Encodable {
    let sessionId: String
    let reason: String?

    init(sessionId: String, reason: String? = nil) {
        self.sessionId = sessionId
        self.reason = reason
    }
}

struct WorktreeAbortMergeResult: Decodable {
    let aborted: Bool
}

// MARK: - Subagent-driven Conflict Resolution

struct WorktreeResolveWithSubagentParams: Encodable {
    let sessionId: String
}

struct WorktreeResolveWithSubagentResult: Decodable {
    let spawned: Bool
    /// Child subagent session id if spawned, null otherwise.
    let subagentSessionId: String?
    /// Parent session id (echoed for correlation).
    let sessionId: String
    /// Human-readable reason when `spawned == false`.
    let reason: String?
}
