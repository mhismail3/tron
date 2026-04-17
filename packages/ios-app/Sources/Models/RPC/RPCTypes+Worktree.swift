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
}

/// Get worktree status for a session
struct WorktreeGetStatusParams: Encodable {
    let sessionId: String
}

struct WorktreeGetStatusResult: Decodable {
    let hasWorktree: Bool
    let worktree: WorktreeInfo?
}

/// Commit changes in a session's worktree
struct WorktreeCommitParams: Encodable {
    let sessionId: String
    let message: String
}

struct WorktreeCommitResult: Decodable {
    let success: Bool
    let commitHash: String?
    let filesChanged: [String]?
    let error: String?
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
    let status: String
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
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        default: return .modified
        }
    }
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

    init(
        sessionId: String,
        sourceBranch: String? = nil,
        targetBranch: String? = nil,
        strategy: String? = nil,
        newBranchName: String? = nil,
        preserveOld: Bool? = nil
    ) {
        self.sessionId = sessionId
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.strategy = strategy
        self.newBranchName = newBranchName
        self.preserveOld = preserveOld
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
