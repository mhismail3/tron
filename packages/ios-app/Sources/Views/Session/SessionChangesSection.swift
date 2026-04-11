import SwiftUI

// MARK: - Session Changes Section

@available(iOS 26.0, *)
struct SessionChangesSection: View {
    let diffResult: WorktreeGetDiffResult?
    let worktreeStatus: WorktreeGetStatusResult?
    let stagedFiles: [DiffFileEntry]
    let unstagedFiles: [DiffFileEntry]
    let branches: [SessionBranchInfo]
    let onFileSelected: (FileDetailData) -> Void
    let onShowAllBranches: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            sectionHeader

            if let diffResult {
                if !diffResult.isGitRepo {
                    notGitRepoView
                } else {
                    changesContent(diffResult: diffResult)
                }
            }

            // View All Branches row
            if diffResult?.isGitRepo == true {
                viewAllBranchesRow
            }
        }
    }

    // MARK: - Section Header

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Changes")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
            Text("Working directory status")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextDisabled)
        }
    }

    // MARK: - Branch + Changes Content

    @ViewBuilder
    private func changesContent(diffResult: WorktreeGetDiffResult) -> some View {
        // Branch name
        branchHeader(diffResult: diffResult)

        // Staged Changes
        if !stagedFiles.isEmpty {
            fileContainer(
                title: "Staged",
                files: stagedFiles,
                accentColor: .tronEmerald,
                stagingArea: .staged
            )
        }

        // Unstaged Changes
        if !unstagedFiles.isEmpty {
            fileContainer(
                title: "Unstaged",
                files: unstagedFiles,
                accentColor: .orange,
                stagingArea: .unstaged
            )
        }

        // No changes
        if stagedFiles.isEmpty && unstagedFiles.isEmpty {
            noChangesView
        }
    }

    // MARK: - Branch Header

    @ViewBuilder
    private func branchHeader(diffResult: WorktreeGetDiffResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Branch name
            if let worktree = worktreeStatus?.worktree {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.tronEmerald)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                    Text(worktree.shortBranch)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                        .lineLimit(1)
                }
            } else if let branch = diffResult.branch {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.tronEmerald)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                    Text(branch)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                        .lineLimit(1)
                }
            }

            // Worktree metadata pills
            if let worktree = worktreeStatus?.worktree {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if worktree.isolated {
                            ToolInfoPill(icon: "lock.shield", label: "Isolated", color: .tronSlate)
                        }
                        let count = worktree.commitCount ?? 0
                        ToolInfoPill(
                            icon: "number",
                            label: count == 1 ? "1 commit" : "\(count) commits",
                            color: .tronSlate
                        )
                        if worktree.isMerged == true {
                            ToolInfoPill(icon: "checkmark.circle", label: "Merged", color: .tronSuccess)
                        }
                    }
                }
                .scrollClipDisabled()
            }

            // File summary pills
            if let summary = diffResult.summary, summary.totalFiles > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ToolInfoPill(
                            icon: "doc.text",
                            label: "\(summary.totalFiles) file\(summary.totalFiles == 1 ? "" : "s")",
                            color: .tronSlate
                        )
                        if summary.totalAdditions > 0 {
                            ToolInfoPill(icon: "plus", label: "\(summary.totalAdditions)", color: .tronSuccess)
                        }
                        if summary.totalDeletions > 0 {
                            ToolInfoPill(icon: "minus", label: "\(summary.totalDeletions)", color: .tronError)
                        }
                    }
                }
                .scrollClipDisabled()
            }

            if diffResult.truncated == true {
                ToolInfoPill(icon: "exclamationmark.triangle", label: "Truncated", color: .yellow)
            }
        }
    }

    // MARK: - File Container

    private func fileContainer(
        title: String,
        files: [DiffFileEntry],
        accentColor: Color,
        stagingArea: StagingArea
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(accentColor)

                Text("\(files.count)")
                    .font(TronTypography.pillValue)
                    .countBadge(accentColor)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // File list
            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    DiffFileRow(file: file) {
                        onFileSelected(FileDetailData(from: file, stagingArea: stagingArea))
                    }
                    if file.id != files.last?.id {
                        Divider()
                            .foregroundStyle(.tronTextMuted.opacity(0.15))
                            .padding(.horizontal)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .sectionFill(accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - View All Branches Row

    private var viewAllBranchesRow: some View {
        Button(action: onShowAllBranches) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronSlate)

                Text("View All Branches")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)

                if !branches.isEmpty {
                    Text("\(branches.count)")
                        .font(TronTypography.pillValue)
                        .countBadge(.tronSlate)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(12)
            .sectionFill(.tronSlate)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty States

    private var noChangesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(TronTypography.sans(size: TronTypography.sizeDisplay))
                .foregroundStyle(.tronSuccess)
            Text("No changes")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var notGitRepoView: some View {
        VStack(spacing: 12) {
            Image(systemName: "info.circle")
                .font(TronTypography.sans(size: TronTypography.sizeDisplay))
                .foregroundStyle(.tronTextMuted)
            Text("Not a Git Repository")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text("This session's working directory is not inside a git repository.")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
