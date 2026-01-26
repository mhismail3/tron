import Foundation

// MARK: - Worktree Methods

/// Worktree information for a session
struct WorktreeInfo: Decodable, Equatable {
    let isolated: Bool
    let branch: String
    let baseCommit: String
    let path: String
    let hasUncommittedChanges: Bool?
    let commitCount: Int?

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

/// List all worktrees
struct WorktreeListItem: Decodable, Identifiable, Hashable {
    let path: String
    let branch: String
    let sessionId: String?

    var id: String { path }
}

struct WorktreeListResult: Decodable {
    let worktrees: [WorktreeListItem]
}
