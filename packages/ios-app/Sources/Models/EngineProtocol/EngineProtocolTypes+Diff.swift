import Foundation

// MARK: - Worktree Diff

struct WorktreeGetDiffParams: Encodable {
    let sessionId: String
}

struct WorktreeGetDiffSummaryParams: Encodable {
    let sessionId: String
}

struct WorktreeGetDiffSummaryResult: Decodable, Equatable {
    let isGitRepo: Bool
    let branch: String?
    let summary: DiffFileSummary?
    let truncated: Bool?
}

struct WorktreeGetDiffResult: Decodable, Equatable {
    let isGitRepo: Bool
    let branch: String?
    let files: [DiffFileEntry]?
    let summary: DiffFileSummary?
    let truncated: Bool?
}

struct DiffFileEntry: Decodable, Identifiable, Equatable {
    let path: String
    let status: FileChangeStatus
    let stagingArea: StagingArea
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
        status
    }

    var fileStagingArea: StagingArea {
        stagingArea
    }
}

enum StagingArea: String, Decodable, Equatable {
    case staged
    case unstaged
    case both
}

enum FileChangeStatus: String, Decodable {
    case modified
    case added
    case deleted
    case renamed
    case untracked
    case unmerged
    case copied
}

struct DiffFileSummary: Decodable, Equatable {
    let totalFiles: Int
    let totalAdditions: Int
    let totalDeletions: Int
}
