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
            } else {
                // Loading placeholder — prevents layout jump when diff arrives
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.tronAmberLight)
                    Text("Loading changes...")
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            // View All Branches row
            if diffResult?.isGitRepo == true || diffResult == nil {
                viewAllBranchesRow
            }
        }
    }

    // MARK: - Section Header

    private var branchName: String? {
        worktreeStatus?.worktree?.shortBranch ?? diffResult?.branch
    }

    private var sectionHeader: some View {
        HStack {
            Text("Changes")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            Spacer()

            if let name = branchName {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.tronAmber)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    Text(name)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronAmber)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Branch + Changes Content

    @ViewBuilder
    private func changesContent(diffResult: WorktreeGetDiffResult) -> some View {
        // Staged Changes
        if !stagedFiles.isEmpty {
            fileContainer(
                title: "Staged",
                files: stagedFiles,
                accentColor: .tronAmberLight,
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
                    .foregroundStyle(.tronAmberLight)

                Text("View All Branches")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)

                if !branches.isEmpty {
                    Text("\(branches.count)")
                        .font(TronTypography.pillValue)
                        .countBadge(.tronAmberLight)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(12)
            .sectionFill(.tronAmberLight)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty States

    private var noChangesView: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronSuccess)
            Text("No changes")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
        }
    }

    private var notGitRepoView: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
            Text("Not a git repository")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
        }
    }
}
