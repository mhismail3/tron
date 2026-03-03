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

    /// Short branch name (removes 'session/' prefix if present)
    var shortBranch: String {
        if branch.hasPrefix("session/") {
            return String(branch.dropFirst(8))
        }
        return branch
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

/// Merge a session's worktree to a target branch
struct WorktreeMergeParams: Encodable {
    let sessionId: String
    let targetBranch: String
    let strategy: String?

    init(sessionId: String, targetBranch: String, strategy: String? = nil) {
        self.sessionId = sessionId
        self.targetBranch = targetBranch
        self.strategy = strategy
    }
}

struct WorktreeMergeResult: Decodable {
    let success: Bool
    let mergeCommit: String?
    let conflicts: [String]?
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
