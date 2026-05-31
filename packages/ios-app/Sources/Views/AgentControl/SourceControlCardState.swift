import Foundation

/// Server-truth projection for the compact Source Control card.
///
/// `worktree.get_status` decides whether source-control actions exist for a
/// session. A session without a worktree must not reuse a previously fetched
/// diff, render source-control affordances, or open a sheet that can only fail
/// server-side.
struct SourceControlCardState: Equatable {
    let branchLabel: String
    let detailLabel: String
    let isGitRepo: Bool?
    let isLoading: Bool
    let isVisible: Bool
    let totalFiles: Int
    let totalAdditions: Int
    let totalDeletions: Int

    init(
        worktreeStatus: WorktreeGetStatusResult?,
        diffResult: WorktreeGetDiffResult?,
        isLoading: Bool,
        workspacePath: String?
    ) {
        self.isLoading = isLoading

        guard let worktreeStatus else {
            branchLabel = "Loading..."
            detailLabel = "Loading..."
            isGitRepo = nil
            isVisible = false
            totalFiles = 0
            totalAdditions = 0
            totalDeletions = 0
            return
        }

        guard worktreeStatus.hasIsolatedWorktree else {
            branchLabel = "No Worktree"
            detailLabel = "No session worktree"
            isGitRepo = nil
            isVisible = false
            totalFiles = 0
            totalAdditions = 0
            totalDeletions = 0
            return
        }

        isVisible = true
        isGitRepo = diffResult?.isGitRepo

        if diffResult?.isGitRepo == false {
            branchLabel = "Untracked"
            detailLabel = workspacePath?.abbreviatingHomeDirectory ?? "Not a git repository"
            totalFiles = 0
            totalAdditions = 0
            totalDeletions = 0
            return
        }

        branchLabel = worktreeStatus.worktree?.shortBranch ?? diffResult?.branch ?? "Loading..."

        let summary = diffResult?.summary
        if let summary {
            totalFiles = summary.totalFiles
            totalAdditions = summary.totalAdditions
            totalDeletions = summary.totalDeletions
        } else {
            let files = diffResult?.files ?? []
            totalFiles = files.count
            totalAdditions = files.reduce(0) { $0 + $1.additions }
            totalDeletions = files.reduce(0) { $0 + $1.deletions }
        }

        if totalFiles > 0 {
            detailLabel = "\(totalFiles) \(totalFiles == 1 ? "file" : "files")"
        } else if diffResult == nil {
            detailLabel = "Loading..."
        } else {
            detailLabel = "No changes"
        }
    }
}
