import Foundation

// MARK: - Source Control Metadata

/// Pure-logic helpers for source control state computation.
/// Extracted from view code for testability.
enum SourceControlMetadata {

    // MARK: - Action Availability

    static func canCommit(
        worktreeStatus: WorktreeGetStatusResult?,
        isLoading: Bool
    ) -> Bool {
        !isLoading && (worktreeStatus?.worktree?.hasUncommittedChanges == true)
    }

    static func canMerge(
        worktreeStatus: WorktreeGetStatusResult?,
        isLoading: Bool
    ) -> Bool {
        !isLoading
            && (worktreeStatus?.worktree?.commitCount ?? 0) > 0
            && worktreeStatus?.worktree?.isMerged != true
    }

    // MARK: - Display Helpers

    static func commitLabel(for status: WorktreeGetStatusResult?) -> String {
        let count = status?.worktree?.commitCount ?? 0
        return count == 1 ? "1 commit" : "\(count) commits"
    }

    static func showTabs(
        diffResult: WorktreeGetDiffResult?,
        worktreeStatus: WorktreeGetStatusResult?,
        branches: [SessionBranchInfo]
    ) -> Bool {
        guard diffResult?.isGitRepo == true else { return false }
        return worktreeStatus?.hasWorktree == true || !branches.isEmpty
    }

    /// Label shown when a file has no diff content, based on its change status.
    static func noChangeLabel(for status: FileChangeStatus) -> String {
        switch status {
        case .untracked: return "New file (untracked)"
        case .deleted: return "File deleted"
        case .added: return "New file"
        case .unmerged: return "Merge conflict"
        case .modified, .renamed, .copied: return "No diff available"
        }
    }

    // MARK: - Content Extraction

    /// Attempts to extract raw file content from an additions-only diff.
    /// Returns nil if the diff contains deletions (mixed diff) or is empty/nil.
    static func extractFileContent(from diff: String?) -> [String]? {
        guard let diff, !diff.isEmpty else { return nil }

        let allLines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var contentLines: [String] = []
        var hasDeletions = false
        var hasAdditions = false
        var inHunk = false

        for line in allLines {
            // Skip file-level headers
            if line.hasPrefix("---") || line.hasPrefix("+++") { continue }
            // Detect hunk start
            if line.hasPrefix("@@") {
                inHunk = true
                continue
            }
            guard inHunk else { continue }

            if line.hasPrefix("-") {
                hasDeletions = true
                break
            } else if line.hasPrefix("+") {
                hasAdditions = true
                contentLines.append(String(line.dropFirst()))
            }
            // Context lines are ignored for pure-addition extraction
        }

        guard hasAdditions && !hasDeletions else { return nil }
        return contentLines
    }
}

// MARK: - FileDetailData

/// Concrete wrapper for `DiffFileDisplayable` to support `.sheet(item:)` presentation.
/// Existential `any DiffFileDisplayable` cannot directly conform to `Identifiable`.
struct FileDetailData: Identifiable, Equatable {
    let id: String
    let path: String
    let fileName: String
    let fileExtension: String
    let changeStatus: FileChangeStatus
    let diff: String?
    let additions: Int
    let deletions: Int
    let stagingArea: StagingArea?

    init(from file: any DiffFileDisplayable) {
        self.id = file.displayPath
        self.path = file.displayPath
        self.fileName = file.displayFileName
        self.fileExtension = file.displayExtension
        self.changeStatus = file.displayChangeStatus
        self.diff = file.displayDiff
        self.additions = file.displayAdditions
        self.deletions = file.displayDeletions
        self.stagingArea = (file as? DiffFileEntry)?.fileStagingArea
    }

    init(from file: any DiffFileDisplayable, stagingArea: StagingArea?) {
        self.id = file.displayPath
        self.path = file.displayPath
        self.fileName = file.displayFileName
        self.fileExtension = file.displayExtension
        self.changeStatus = file.displayChangeStatus
        self.diff = file.displayDiff
        self.additions = file.displayAdditions
        self.deletions = file.displayDeletions
        self.stagingArea = stagingArea
    }
}
