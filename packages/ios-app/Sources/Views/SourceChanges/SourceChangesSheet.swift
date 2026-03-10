import SwiftUI

@available(iOS 26.0, *)
struct SourceChangesSheet: View {
    let rpcClient: RPCClient
    let sessionId: String
    let onAskAgent: ((String) -> Void)?

    init(rpcClient: RPCClient, sessionId: String, onAskAgent: ((String) -> Void)? = nil) {
        self.rpcClient = rpcClient
        self.sessionId = sessionId
        self.onAskAgent = onAskAgent
    }

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var selectedTab: SourceControlTab = .thisSession
    @State private var result: WorktreeGetDiffResult?
    @State private var worktreeStatus: WorktreeGetStatusResult?
    @State private var committedResult: CommittedDiffResult?
    @State private var branches: [SessionBranchInfo] = []
    @State private var isLoading = true
    @State private var isWorktreeLoading = false
    @State private var isBranchesLoading = true
    @State private var errorMessage: String?
    @State private var expandedFiles: Set<String> = []
    @State private var expandedCommittedFiles: Set<String> = []
    @State private var selectedBranch: SessionBranchInfo?

    enum SourceControlTab: String, CaseIterable {
        case thisSession = "This Session"
        case allBranches = "All Branches"
    }

    /// Show the segmented picker only when there's something to show in "All Branches"
    private var showTabs: Bool {
        guard result?.isGitRepo == true else { return false }
        return worktreeStatus?.hasWorktree == true || !branches.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showTabs {
                    Picker("", selection: $selectedTab) {
                        ForEach(SourceControlTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                ZStack {
                    switch selectedTab {
                    case .thisSession:
                        thisSessionContent
                    case .allBranches:
                        allBranchesContent
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image("IconGit")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .foregroundStyle(.tronEmerald)
                        Text("Source Control")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .task { await loadAll() }
        .sheet(item: $selectedBranch) { branch in
            BranchDetailView(
                branch: branch,
                rpcClient: rpcClient,
                currentSessionId: sessionId,
                onAskAgent: { message in
                    selectedBranch = nil
                    dismiss()
                    onAskAgent?(message)
                }
            )
            .presentationDragIndicator(.hidden)
            .adaptivePresentationDetents([.medium, .large])
        }
    }

    // MARK: - This Session Content

    @ViewBuilder
    private var thisSessionContent: some View {
        if isLoading {
            loadingView
        } else if let error = errorMessage {
            errorView(error)
        } else if let result, !result.isGitRepo {
            notGitRepoView
        } else {
            thisSessionFileList
        }
    }

    @ViewBuilder
    private var thisSessionFileList: some View {
        let hasWorktree = worktreeStatus?.hasWorktree == true
        let uncommittedFiles = result?.files ?? []
        let committedFiles = committedResult?.files ?? []
        let commits = committedResult?.commits ?? []
        let hasAnyContent = !uncommittedFiles.isEmpty || !committedFiles.isEmpty || hasWorktree

        if !hasAnyContent {
            noChangesView
        } else {
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 16) {
                        if hasWorktree {
                            WorktreeStatusView(
                                status: worktreeStatus!,
                                isLoading: isWorktreeLoading,
                                onCommit: { commitWorktreeChanges() },
                                onMerge: { mergeWorktreeChanges() }
                            )
                            .padding(.horizontal)
                        }

                        if let result {
                            summaryHeader(result: result, files: uncommittedFiles)
                                .padding(.horizontal)
                        }

                        if hasWorktree && (!commits.isEmpty || !committedFiles.isEmpty) {
                            committedChangesSection(commits: commits, files: committedFiles)
                        }

                        if hasWorktree && !uncommittedFiles.isEmpty {
                            uncommittedSection(files: uncommittedFiles)
                        } else if !hasWorktree && !uncommittedFiles.isEmpty {
                            LazyVStack(spacing: 0) {
                                ForEach(uncommittedFiles) { file in
                                    DiffFileRow(
                                        file: file,
                                        isExpanded: expandedFiles.contains(file.path),
                                        onToggle: { toggleFile(file.path, in: &expandedFiles) }
                                    )
                                    if file.id != uncommittedFiles.last?.id {
                                        Divider()
                                            .foregroundStyle(.tronTextMuted.opacity(0.15))
                                            .padding(.horizontal)
                                    }
                                }
                            }
                        }

                        if hasWorktree && uncommittedFiles.isEmpty && committedFiles.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "checkmark.circle")
                                    .font(TronTypography.sans(size: TronTypography.sizeDisplay))
                                    .foregroundStyle(.tronSuccess)
                                Text("No changes")
                                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                                    .foregroundStyle(.tronTextPrimary)
                            }
                            .padding(.vertical, 20)
                        }
                    }
                    .padding(.vertical)
                    .frame(width: geometry.size.width)
                }
                .refreshable { await loadAll() }
            }
        }
    }

    // MARK: - Committed Changes Section

    private func committedChangesSection(commits: [CommitEntry], files: [CommittedFileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Committed Changes (\(commits.count) commit\(commits.count == 1 ? "" : "s"))")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
                .padding(.horizontal)

            if !commits.isEmpty {
                VStack(spacing: 0) {
                    ForEach(commits) { commit in
                        HStack(spacing: 8) {
                            Text(commit.shortHash)
                                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronEmerald)
                            Text(commit.message)
                                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextPrimary)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }
                }
            }

            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    DiffFileRow(
                        file: file,
                        isExpanded: expandedCommittedFiles.contains(file.path),
                        onToggle: { toggleFile(file.path, in: &expandedCommittedFiles) }
                    )
                    if file.id != files.last?.id {
                        Divider()
                            .foregroundStyle(.tronTextMuted.opacity(0.15))
                            .padding(.horizontal)
                    }
                }
            }
        }
    }

    // MARK: - Uncommitted Section

    private func uncommittedSection(files: [DiffFileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Uncommitted Changes")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
                .padding(.horizontal)

            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    DiffFileRow(
                        file: file,
                        isExpanded: expandedFiles.contains(file.path),
                        onToggle: { toggleFile(file.path, in: &expandedFiles) }
                    )
                    if file.id != files.last?.id {
                        Divider()
                            .foregroundStyle(.tronTextMuted.opacity(0.15))
                            .padding(.horizontal)
                    }
                }
            }
        }
    }

    // MARK: - All Branches Content

    @ViewBuilder
    private var allBranchesContent: some View {
        if isBranchesLoading {
            loadingView
        } else if branches.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeDisplay))
                    .foregroundStyle(.tronTextMuted)
                Text("No session branches found")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Active sessions (excluding current)
                    let activeBranches = branches.filter { $0.isActive && $0.sessionId != sessionId }
                    if !activeBranches.isEmpty {
                        sectionHeader("Active Sessions")
                        ForEach(activeBranches) { branch in
                            branchRow(branch)
                        }
                    }

                    // Preserved branches
                    let preservedBranches = branches.filter { !$0.isActive }
                    if !preservedBranches.isEmpty {
                        sectionHeader("Preserved Branches")
                        ForEach(preservedBranches) { branch in
                            branchRow(branch)
                        }
                    }

                    // Current session branch
                    let currentBranches = branches.filter { $0.isActive && $0.sessionId == sessionId }
                    if !currentBranches.isEmpty {
                        sectionHeader("Current Session")
                        ForEach(currentBranches) { branch in
                            branchRow(branch)
                        }
                    }
                }
                .padding(.vertical)
            }
            .refreshable { await loadBranches() }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(.tronTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func branchRow(_ branch: SessionBranchInfo) -> some View {
        Button {
            selectedBranch = branch
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(branch.shortBranch)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)

                    Text(branch.lastCommitMessage)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                }

                Spacer()

                if branch.commitCount > 0 {
                    Text("\(branch.commitCount)")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }

                if !branch.isActive {
                    Text("Ended")
                        .font(TronTypography.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summary Header

    private func summaryHeader(result: WorktreeGetDiffResult, files: [DiffFileEntry]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let branch = result.branch {
                    ToolInfoPill(
                        icon: "arrow.triangle.branch",
                        label: branch,
                        color: .tronEmerald
                    )
                }
                if let summary = result.summary {
                    ToolInfoPill(
                        icon: "doc.text",
                        label: "\(summary.totalFiles) file\(summary.totalFiles == 1 ? "" : "s")",
                        color: .tronSlate
                    )
                    if summary.totalAdditions > 0 {
                        ToolInfoPill(
                            icon: "plus",
                            label: "\(summary.totalAdditions)",
                            color: .tronSuccess
                        )
                    }
                    if summary.totalDeletions > 0 {
                        ToolInfoPill(
                            icon: "minus",
                            label: "\(summary.totalDeletions)",
                            color: .tronError
                        )
                    }
                }
                if result.truncated == true {
                    ToolInfoPill(
                        icon: "exclamationmark.triangle",
                        label: "Truncated",
                        color: .yellow
                    )
                }
            }
        }
    }

    // MARK: - Common Views

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
                .font(TronTypography.sans(size: TronTypography.sizeDisplay))
                .foregroundStyle(.tronError)
            Text(message)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") { Task { await loadAll() } }
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronEmerald)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noChangesView: some View {
        VStack(spacing: 16) {
            if let status = worktreeStatus, status.hasWorktree {
                WorktreeStatusView(
                    status: status,
                    isLoading: isWorktreeLoading,
                    onCommit: { commitWorktreeChanges() },
                    onMerge: { mergeWorktreeChanges() }
                )
                .padding(.horizontal)
            }

            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeDisplay))
                    .foregroundStyle(.tronSuccess)
                Text("No uncommitted changes")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func toggleFile(_ path: String, in set: inout Set<String>) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if set.contains(path) {
                set.remove(path)
            } else {
                set.insert(path)
            }
        }
    }

    // MARK: - Data Loading

    private func loadAll() async {
        isLoading = true
        errorMessage = nil
        expandedFiles = []
        expandedCommittedFiles = []

        async let diffResult = rpcClient.misc.getWorkingDirectoryDiff(sessionId: sessionId)
        async let statusResult: WorktreeGetStatusResult? = {
            try? await rpcClient.misc.getWorktreeStatus(sessionId: sessionId)
        }()
        async let committedDiffResult: CommittedDiffResult? = {
            try? await rpcClient.misc.getCommittedDiff(sessionId: sessionId)
        }()

        do {
            result = try await diffResult
        } catch {
            errorMessage = "Failed to load changes: \(error.localizedDescription)"
        }
        worktreeStatus = await statusResult
        committedResult = await committedDiffResult
        isLoading = false

        await loadBranches()
    }

    private func loadBranches() async {
        isBranchesLoading = true
        branches = (try? await rpcClient.misc.listSessionBranches(sessionId: sessionId)) ?? []
        isBranchesLoading = false
    }

    // MARK: - Worktree Actions

    private func commitWorktreeChanges() {
        Task {
            isWorktreeLoading = true
            defer { isWorktreeLoading = false }

            do {
                let result = try await rpcClient.misc.commitWorktree(
                    sessionId: sessionId,
                    message: "Manual commit from iOS"
                )
                if result.success {
                    await loadAll()
                }
            } catch {
                errorMessage = "Commit failed: \(error.localizedDescription)"
            }
        }
    }

    private func mergeWorktreeChanges() {
        Task {
            isWorktreeLoading = true
            defer { isWorktreeLoading = false }

            do {
                let targetBranch = worktreeStatus?.worktree?.baseBranch ?? "main"
                let mergeResult = try await rpcClient.misc.mergeWorktree(
                    sessionId: sessionId,
                    targetBranch: targetBranch
                )
                if !mergeResult.success {
                    if let conflicts = mergeResult.conflicts, !conflicts.isEmpty {
                        errorMessage = "Merge conflicts in: \(conflicts.joined(separator: ", "))"
                    } else if let error = mergeResult.error {
                        errorMessage = error
                    }
                }
                await loadAll()
            } catch {
                errorMessage = "Merge failed: \(error.localizedDescription)"
            }
        }
    }
}
