import SwiftUI

/// Detail view for a session branch showing commits and changed files.
/// Pushed via NavigationLink within SourceChangesSheet's NavigationStack.
@available(iOS 26.0, *)
struct BranchDetailView: View {
    let branch: SessionBranchInfo
    let rpcClient: RPCClient
    let currentSessionId: String
    let onAskAgent: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var committedDiff: CommittedDiffResult?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var expandedFiles: Set<String> = []
    @State private var showMergeConfirmation = false
    @State private var isMerging = false
    @State private var mergeSuccess: String?
    @State private var mergeError: String?
    @State private var mergeConflicts: [String] = []
    @State private var showConflictAlert = false

    private var targetBranch: String {
        branch.baseBranch ?? "main"
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(branch.shortBranch)
                .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(.tronEmerald)
                .padding(.top, 20)
                .padding(.bottom, 12)

            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else {
                detailContent
            }
        }
        .task { await loadCommittedDiff() }
        .confirmationDialog(
            "Merge \(branch.shortBranch) into \(targetBranch)",
            isPresented: $showMergeConfirmation
        ) {
            Button("Merge (default)") { performMerge(strategy: nil) }
            Button("Rebase") { performMerge(strategy: "rebase") }
            Button("Squash") { performMerge(strategy: "squash") }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Merge Conflicts", isPresented: $showConflictAlert) {
            Button("Ask Agent to Merge") {
                let message = "Please merge branch \(branch.branch) into \(targetBranch) and resolve any conflicts"
                onAskAgent(message)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Conflicts in:\n\(mergeConflicts.joined(separator: "\n"))")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                actionButtons

                if let diff = committedDiff {
                    if !diff.commits.isEmpty {
                        commitsSection(diff.commits)
                    }

                    if !diff.files.isEmpty {
                        filesSection(diff.files)
                    }

                    if diff.commits.isEmpty && diff.files.isEmpty {
                        emptyState
                    }
                } else {
                    emptyState
                }
            }
            .padding()
        }
        .refreshable { await loadCommittedDiff() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ToolInfoPill(
                    icon: "arrow.triangle.branch",
                    label: branch.shortBranch,
                    color: .tronEmerald
                )

                Text(branch.isActive ? "Active" : "Ended")
                    .font(TronTypography.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(branch.isActive ? .tronSuccess : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }

            if let base = branch.baseBranch {
                Text("Based on \(base)")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }

            if let diff = committedDiff {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ToolInfoPill(
                            icon: "doc.text",
                            label: "\(diff.summary.totalFiles) file\(diff.summary.totalFiles == 1 ? "" : "s")",
                            color: .tronSlate
                        )
                        if diff.summary.totalAdditions > 0 {
                            ToolInfoPill(
                                icon: "plus",
                                label: "\(diff.summary.totalAdditions)",
                                color: .tronSuccess
                            )
                        }
                        if diff.summary.totalDeletions > 0 {
                            ToolInfoPill(
                                icon: "minus",
                                label: "\(diff.summary.totalDeletions)",
                                color: .tronError
                            )
                        }
                        if diff.truncated {
                            ToolInfoPill(
                                icon: "exclamationmark.triangle",
                                label: "Truncated",
                                color: .yellow
                            )
                        }
                    }
                }
            }

            if let success = mergeSuccess {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tronSuccess)
                    Text("Merged: \(String(success.prefix(7)))")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronSuccess)
                }
            }

            if let error = mergeError {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tronError)
                    Text(error)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronError)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                showMergeConfirmation = true
            } label: {
                Label("Merge", systemImage: "arrow.triangle.merge")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.tronEmerald)
                    .clipShape(Capsule())
                    .opacity(isMerging || branch.commitCount == 0 ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(isMerging || branch.commitCount == 0)

            Button {
                let message = "Please merge branch \(branch.branch) into \(targetBranch) and resolve any conflicts"
                onAskAgent(message)
            } label: {
                Label("Ask Agent", systemImage: "bubble.left.and.text.bubble.right")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            if isMerging {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()
        }
    }

    // MARK: - Commits Section

    private func commitsSection(_ commits: [CommitEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Commits (\(commits.count))")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(commits) { commit in
                    HStack(spacing: 8) {
                        Text(commit.shortHash)
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronEmerald)

                        Text(commit.message)
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.vertical, 6)

                    if commit.id != commits.last?.id {
                        Divider()
                            .foregroundStyle(.tronTextMuted.opacity(0.15))
                    }
                }
            }
        }
    }

    // MARK: - Files Section

    private func filesSection(_ files: [CommittedFileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Changed Files (\(files.count))")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
                .padding(.bottom, 8)

            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    DiffFileRow(
                        file: file,
                        isExpanded: expandedFiles.contains(file.path),
                        onToggle: {
                            if expandedFiles.contains(file.path) {
                                expandedFiles.remove(file.path)
                            } else {
                                expandedFiles.insert(file.path)
                            }
                        }
                    )
                    if file.id != files.last?.id {
                        Divider()
                            .foregroundStyle(.tronTextMuted.opacity(0.15))
                    }
                }
            }
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.tronEmerald)
            Text("Loading changes...")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.tronError)
            Text(message)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") { Task { await loadCommittedDiff() } }
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronEmerald)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.tronSuccess)
            Text(branch.commitCount == 0 ? "No commits yet" : "Already merged")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Data Loading

    private func loadCommittedDiff() async {
        isLoading = true
        errorMessage = nil

        do {
            let sid = branch.sessionId ?? currentSessionId
            committedDiff = try await rpcClient.misc.getCommittedDiff(sessionId: sid)
        } catch {
            errorMessage = "Failed to load changes: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Merge

    private func performMerge(strategy: String?) {
        Task {
            isMerging = true
            mergeError = nil
            mergeSuccess = nil
            defer { isMerging = false }

            do {
                let result = try await rpcClient.misc.mergeWorktree(
                    sessionId: branch.sessionId ?? currentSessionId,
                    targetBranch: targetBranch,
                    strategy: strategy
                )

                if result.success {
                    mergeSuccess = result.mergeCommit ?? "done"
                    await loadCommittedDiff()
                } else if let conflicts = result.conflicts, !conflicts.isEmpty {
                    mergeConflicts = conflicts
                    showConflictAlert = true
                } else {
                    mergeError = result.error ?? "Merge failed"
                }
            } catch {
                mergeError = "Merge failed: \(error.localizedDescription)"
            }
        }
    }
}
