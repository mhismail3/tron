import SwiftUI

/// Detail view for a session branch showing commits and changed files.
/// Presented from AllBranchesSheet when tapping a branch row.
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
    @State private var selectedFileDetail: FileDetailData?
    @State private var showMergeConfirmation = false
    @State private var isMerging = false
    @State private var mergeSuccess: String?
    @State private var mergeError: String?
    @State private var mergeConflicts: [String] = []
    @State private var showConflictAlert = false
    @State private var showDeleteBranchConfirmation = false
    @State private var isDeleting = false

    private var targetBranch: String {
        branch.baseBranch ?? "main"
    }

    private var canMerge: Bool {
        !isMerging && branch.commitCount > 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if isLoading {
                    loadingView
                } else if let error = errorMessage {
                    errorView(error)
                } else {
                    detailContent
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    mergeButton
                    askAgentButton
                }
                ToolbarItem(placement: .principal) {
                    Text(branch.shortBranch)
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTeal)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { await loadCommittedDiff() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronTeal)
                    }
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronTeal)
                    }
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
            .confirmationDialog(
                "Delete branch?",
                isPresented: $showDeleteBranchConfirmation
            ) {
                Button("Delete (\(branch.commitCount) unmerged commit\(branch.commitCount == 1 ? "" : "s"))", role: .destructive) {
                    performDelete()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Branch \(branch.shortBranch) has \(branch.commitCount) unmerged commit\(branch.commitCount == 1 ? "" : "s"). This cannot be undone.")
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
        .tint(.tronTeal)
    }

    // MARK: - Toolbar Buttons

    @ViewBuilder
    private var mergeButton: some View {
        Button { showMergeConfirmation = true } label: {
            if isMerging {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.triangle.merge")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(canMerge ? .tronTeal : .tronTextMuted.opacity(0.5))
            }
        }
        .disabled(!canMerge)
        .accessibilityLabel("Merge")
    }

    private var askAgentButton: some View {
        Button {
            let message = "Please merge branch \(branch.branch) into \(targetBranch) and resolve any conflicts"
            onAskAgent(message)
        } label: {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTeal)
        }
        .accessibilityLabel("Ask Agent")
    }

    // MARK: - Content

    @ViewBuilder
    private var detailContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    statusBanner

                    if let diff = committedDiff {
                        if !diff.commits.isEmpty {
                            commitsSection(diff.commits)
                        }

                        if !diff.files.isEmpty {
                            filesSection(diff.files)
                        }

                        if diff.commits.isEmpty && diff.files.isEmpty {
                            emptyState(availableHeight: geometry.size.height)
                        }
                    } else {
                        emptyState(availableHeight: geometry.size.height)
                    }
                }
                .padding()
                .frame(width: geometry.size.width)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status + base branch
            HStack(spacing: 8) {
                Text(branch.isActive ? "Active" : "Ended")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(branch.isActive ? .tronTeal : .tronTextMuted)

                if let base = branch.baseBranch {
                    Text("·")
                        .foregroundStyle(.tronTextDisabled)
                    Text("Based on \(base)")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }

                Spacer()

                if !branch.isActive {
                    deleteButton
                }
            }

            // File stats
            if let diff = committedDiff {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        Text("\(diff.summary.totalFiles) \(diff.summary.totalFiles == 1 ? "file" : "files")")
                    }
                    .foregroundStyle(.tronTextMuted)

                    if diff.summary.totalAdditions > 0 {
                        Text("+\(diff.summary.totalAdditions)")
                            .foregroundStyle(.tronSuccess)
                    }
                    if diff.summary.totalDeletions > 0 {
                        Text("−\(diff.summary.totalDeletions)")
                            .foregroundStyle(.tronError)
                    }
                    if diff.truncated {
                        Text("Truncated")
                            .foregroundStyle(.tronWarning)
                    }
                }
                .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
            }
        }
    }

    // MARK: - Status Banner

    @ViewBuilder
    private var statusBanner: some View {
        if let success = mergeSuccess {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tronSuccess)
                Text("Merged: \(String(success.prefix(7)))")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronSuccess)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectionFill(.tronSuccess)
        }

        if let error = mergeError {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tronError)
                Text(error)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectionFill(.tronError)
        }
    }

    // MARK: - Delete Button

    private var deleteButton: some View {
        Button {
            if branch.commitCount > 0 {
                showDeleteBranchConfirmation = true
            } else {
                performDelete()
            }
        } label: {
            HStack(spacing: 4) {
                if isDeleting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "trash")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                }
                Text("Delete")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
            }
            .foregroundStyle(.tronError)
        }
        .buttonStyle(.plain)
        .disabled(isDeleting)
    }

    // MARK: - Commits Section

    private func commitsSection(_ commits: [CommitEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Commits")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTeal)
                Text("\(commits.count)")
                    .font(TronTypography.pillValue)
                    .countBadge(.tronTeal)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            LazyVStack(spacing: 0) {
                ForEach(commits) { commit in
                    HStack(spacing: 8) {
                        Text(commit.shortHash)
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTeal)

                        Text(commit.message)
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    if commit.id != commits.last?.id {
                        Divider()
                            .foregroundStyle(.tronTextMuted.opacity(0.15))
                            .padding(.horizontal)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .sectionFill(.tronTeal)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Files Section

    private func filesSection(_ files: [CommittedFileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changed Files")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTeal)
                Text("\(files.count)")
                    .font(TronTypography.pillValue)
                    .countBadge(.tronTeal)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    DiffFileRow(file: file) {
                        selectedFileDetail = FileDetailData(from: file)
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
        .sectionFill(.tronTeal)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(item: $selectedFileDetail) { fileData in
            FileDetailSheet(file: fileData)
                .presentationDragIndicator(.hidden)
                .adaptivePresentationDetents([.medium, .large])
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.tronTeal)
            Text("Loading changes...")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.tronError)
            Text(message)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") { Task { await loadCommittedDiff() } }
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTeal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(availableHeight: CGFloat) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.tronTeal)
            Text(branch.commitCount == 0 ? "No commits yet" : "Already merged")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, minHeight: max(availableHeight - 120, 150))
    }

    // MARK: - Data Loading

    private func loadCommittedDiff() async {
        isLoading = true
        errorMessage = nil

        do {
            let sid = branch.sessionId ?? currentSessionId
            committedDiff = try await rpcClient.worktree.getCommittedDiff(sessionId: sid)
        } catch {
            errorMessage = "Failed to load changes: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Delete

    private func performDelete() {
        Task {
            isDeleting = true
            defer { isDeleting = false }

            do {
                let _ = try await rpcClient.worktree.deleteBranch(
                    sessionId: branch.sessionId ?? currentSessionId,
                    branch: branch.branch
                )
                dismiss()
            } catch {
                mergeError = "Delete failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Merge

    private func performMerge(strategy: String?) {
        Task {
            isMerging = true
            mergeError = nil
            mergeSuccess = nil
            defer { isMerging = false }

            do {
                let result = try await rpcClient.worktree.merge(
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
