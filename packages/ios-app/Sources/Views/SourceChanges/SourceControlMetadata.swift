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

    // MARK: - Display Helpers

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

    /// Extracts the "after" state of a file from its unified diff.
    /// For additions-only diffs, returns just the added lines.
    /// For mixed diffs, reconstructs the result by keeping context lines and
    /// additions while skipping deletions.
    static func extractFileContent(from diff: String?) -> [String]? {
        guard let diff, !diff.isEmpty else { return nil }

        let allLines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var contentLines: [String] = []
        var inHunk = false

        for line in allLines {
            if line.hasPrefix("---") || line.hasPrefix("+++") { continue }
            if line.hasPrefix("@@") {
                inHunk = true
                continue
            }
            guard inHunk else { continue }

            if line.hasPrefix("-") {
                // Deletion — skip (not in the "after" state)
                continue
            } else if line.hasPrefix("+") {
                contentLines.append(String(line.dropFirst()))
            } else {
                // Context line (starts with space) — part of the file
                contentLines.append(line.hasPrefix(" ") ? String(line.dropFirst()) : line)
            }
        }

        return contentLines.isEmpty ? nil : contentLines
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
