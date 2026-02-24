import Foundation

// MARK: - Worktree Diff

struct WorktreeGetDiffParams: Encodable {
    let sessionId: String
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
        FileChangeStatus(rawValue: status) ?? .modified
    }
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
