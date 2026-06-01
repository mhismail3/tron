import Foundation

/// Server-truth projection for the compact Source Control card.
///
/// `worktree.get_status` decides whether source-control actions exist for a
/// session. Isolated worktrees and passthrough repo checkouts both render; a
/// session outside git must not reuse a previously fetched diff or open a
/// source-control sheet that can only fail server-side.
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
        diffSummaryResult: WorktreeGetDiffSummaryResult?,
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

        guard worktreeStatus.hasSourceControlCheckout else {
            branchLabel = "No Source Control"
            detailLabel = "No git checkout"
            isGitRepo = nil
            isVisible = false
            totalFiles = 0
            totalAdditions = 0
            totalDeletions = 0
            return
        }

        isVisible = true
        isGitRepo = diffSummaryResult?.isGitRepo ?? true
        let isPassthrough = worktreeStatus.worktree?.isolated == false

        if diffSummaryResult?.isGitRepo == false {
            branchLabel = "Untracked"
            detailLabel = workspacePath?.abbreviatingHomeDirectory ?? "Not a git repository"
            totalFiles = 0
            totalAdditions = 0
            totalDeletions = 0
            return
        }

        branchLabel = worktreeStatus.worktree?.shortBranch ?? diffSummaryResult?.branch ?? "Repository"

        let summary = diffSummaryResult?.summary
        if let summary {
            totalFiles = summary.totalFiles
            totalAdditions = summary.totalAdditions
            totalDeletions = summary.totalDeletions
        } else {
            totalFiles = 0
            totalAdditions = 0
            totalDeletions = 0
        }

        if totalFiles > 0 {
            detailLabel = "\(totalFiles) \(totalFiles == 1 ? "file" : "files")"
        } else if worktreeStatus.worktree?.hasUncommittedChanges == true && diffSummaryResult == nil {
            detailLabel = isLoading ? "Changes" : "Changes unavailable"
        } else if isPassthrough {
            detailLabel = "Direct branch"
        } else {
            detailLabel = "No changes"
        }
    }
}
