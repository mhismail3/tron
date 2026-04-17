import SwiftUI

// MARK: - Session Changes Section

@available(iOS 26.0, *)
struct SessionChangesSection: View {
    let diffResult: WorktreeGetDiffResult?
    let worktreeStatus: WorktreeGetStatusResult?
    let stagedFiles: [DiffFileEntry]
    let unstagedFiles: [DiffFileEntry]
    let onFileSelected: (FileDetailData) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            sectionHeader

            if let diffResult {
                if !diffResult.isGitRepo {
                    notGitRepoSubtext
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
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
    }

    // MARK: - Section Header

    private var totalFiles: Int {
        stagedFiles.count + unstagedFiles.count
    }

    private var totalAdditions: Int {
        (stagedFiles + unstagedFiles).reduce(0) { $0 + $1.additions }
    }

    private var totalDeletions: Int {
        (stagedFiles + unstagedFiles).reduce(0) { $0 + $1.deletions }
    }

    private var sectionHeader: some View {
        Group {
            if diffResult != nil && totalFiles > 0 {
                HStack(spacing: 6) {
                    Text("\(totalFiles) \(totalFiles == 1 ? "file" : "files")")
                        .foregroundStyle(.tronTextMuted)
                    if totalAdditions > 0 {
                        Text("+\(totalAdditions)")
                            .foregroundStyle(.tronSuccess)
                    }
                    if totalDeletions > 0 {
                        Text("−\(totalDeletions)")
                            .foregroundStyle(.tronError)
                    }
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
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
                accentColor: .tronAmber,
                stagingArea: .unstaged
            )
        }

        // No changes — compact inline subtext below the git action containers.
        if stagedFiles.isEmpty && unstagedFiles.isEmpty {
            cleanTreeSubtext
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
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
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

    // MARK: - Empty States

    /// Compact one-line subtext shown below the git action containers when the
    /// working tree has no changes. Replaces the older centered icon + large
    /// text empty state so the layout stays tight.
    private var cleanTreeSubtext: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
            Text("Working tree is clean.")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
        }
        .foregroundStyle(.tronTextMuted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    /// Compact one-line subtext shown when the session's CWD is not a git
    /// repo. Same treatment as `cleanTreeSubtext` to keep the layout
    /// consistent.
    private var notGitRepoSubtext: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.circle")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
            Text("Not a git repository.")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
        }
        .foregroundStyle(.tronTextMuted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}
