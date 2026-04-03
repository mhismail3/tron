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
    @State private var isCommitting = false
    @State private var isMerging = false
    @State private var isBranchesLoading = true
    @State private var errorMessage: String?
    @State private var selectedBranch: SessionBranchInfo?
    @State private var selectedFileDetail: FileDetailData?
    @State private var isPruning = false
    @State private var showPruneConfirmation = false
    @State private var showCommitConfirmation = false
    @State private var showMergeConfirmation = false

    enum SourceControlTab: String, CaseIterable {
        case thisSession = "This Session"
        case allBranches = "All Branches"
    }

    // MARK: - Computed Properties

    private var showTabs: Bool {
        SourceControlMetadata.showTabs(
            diffResult: result,
            worktreeStatus: worktreeStatus,
            branches: branches
        )
    }

    private var canCommit: Bool {
        SourceControlMetadata.canCommit(
            worktreeStatus: worktreeStatus,
            isLoading: isCommitting
        )
    }

    private var canMerge: Bool {
        SourceControlMetadata.canMerge(
            worktreeStatus: worktreeStatus,
            isLoading: isMerging
        )
    }

    private var hasInactiveBranches: Bool {
        branches.contains { !$0.isActive }
    }

    // MARK: - Body

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
                ToolbarItemGroup(placement: .topBarLeading) {
                    if selectedTab == .thisSession && worktreeStatus?.hasWorktree == true {
                        commitButton
                        mergeButton
                    } else if selectedTab == .allBranches && hasInactiveBranches {
                        pruneButton
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
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
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .task { await loadAll() }
        .sheet(item: $selectedBranch, onDismiss: {
            Task { await loadBranches() }
        }) { branch in
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
        .sheet(item: $selectedFileDetail) { fileData in
            FileDetailSheet(file: fileData)
                .presentationDragIndicator(.hidden)
                .adaptivePresentationDetents([.medium, .large])
        }
    }

    // MARK: - Toolbar Buttons

    @ViewBuilder
    private var commitButton: some View {
        Button { showCommitConfirmation = true } label: {
            if isCommitting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(canCommit ? .tronEmerald : .tronTextMuted.opacity(0.5))
            }
        }
        .disabled(!canCommit || isCommitting)
        .accessibilityLabel("Commit")
        .popover(isPresented: $showCommitConfirmation, arrowEdge: .top) {
            GlassActionSheet(
                actions: [
                    GlassAction(
                        title: "Commit Changes",
                        icon: "checkmark.circle",
                        color: .tronEmerald,
                        role: .default
                    ) {
                        showCommitConfirmation = false
                        commitWorktreeChanges()
                    },
                    GlassAction(
                        title: "Cancel",
                        icon: nil,
                        color: .tronTextMuted,
                        role: .cancel
                    ) {
                        showCommitConfirmation = false
                    }
                ]
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var mergeButton: some View {
        Button { showMergeConfirmation = true } label: {
            if isMerging {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.triangle.merge")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(canMerge ? .tronEmerald : .tronTextMuted.opacity(0.5))
            }
        }
        .disabled(!canMerge || isMerging)
        .accessibilityLabel("Merge")
        .popover(isPresented: $showMergeConfirmation, arrowEdge: .top) {
            GlassActionSheet(
                actions: [
                    GlassAction(
                        title: "Merge to \(worktreeStatus?.worktree?.baseBranch ?? "main")",
                        icon: "arrow.triangle.merge",
                        color: .tronEmerald,
                        role: .default
                    ) {
                        showMergeConfirmation = false
                        mergeWorktreeChanges()
                    },
                    GlassAction(
                        title: "Cancel",
                        icon: nil,
                        color: .tronTextMuted,
                        role: .cancel
                    ) {
                        showMergeConfirmation = false
                    }
                ]
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var pruneButton: some View {
        Button { showPruneConfirmation = true } label: {
            if isPruning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Prune", systemImage: "trash")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronError)
            }
        }
        .disabled(isPruning)
        .popover(isPresented: $showPruneConfirmation, arrowEdge: .bottom) {
            GlassActionSheet(
                actions: [
                    GlassAction(
                        title: "Delete all \(branches.filter({ !$0.isActive }).count) branches",
                        icon: "trash",
                        color: .tronError,
                        role: .destructive
                    ) {
                        showPruneConfirmation = false
                        pruneAllBranches()
                    },
                    GlassAction(
                        title: "Cancel",
                        icon: nil,
                        color: .tronTextMuted,
                        role: .cancel
                    ) {
                        showPruneConfirmation = false
                    }
                ]
            )
            .presentationCompactAdaptation(.popover)
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
                        unifiedHeader
                            .padding(.horizontal)

                        if hasWorktree && (!commits.isEmpty || !committedFiles.isEmpty) {
                            committedChangesSection(commits: commits, files: committedFiles)
                        }

                        if !uncommittedFiles.isEmpty {
                            if hasWorktree {
                                uncommittedSection(files: uncommittedFiles)
                            } else {
                                plainFileList(files: uncommittedFiles)
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

    // MARK: - Unified Header

    @ViewBuilder
    private var unifiedHeader: some View {
        let hasWorktree = worktreeStatus?.hasWorktree == true

        VStack(alignment: .leading, spacing: 8) {
            // Row 1: Branch name
            if hasWorktree, let worktree = worktreeStatus?.worktree {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.tronEmerald)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                    Text(worktree.shortBranch)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                        .lineLimit(1)
                }
            } else if let branch = result?.branch {
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

            // Row 2: Worktree metadata pills
            if hasWorktree, let worktree = worktreeStatus?.worktree {
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

                        if worktree.hasUncommittedChanges == true {
                            ToolInfoPill(icon: "circle.fill", label: "Uncommitted", color: .orange)
                        }

                        if worktree.isMerged == true {
                            ToolInfoPill(icon: "checkmark.circle", label: "Merged", color: .tronSuccess)
                        }
                    }
                }
                .scrollClipDisabled()
            }

            // Row 3: File summary pills
            if let result {
                fileSummaryPills(result: result)
            }
        }
    }

    private func fileSummaryPills(result: WorktreeGetDiffResult) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let summary = result.summary {
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
                if result.truncated == true {
                    ToolInfoPill(icon: "exclamationmark.triangle", label: "Truncated", color: .yellow)
                }
            }
        }
        .scrollClipDisabled()
    }

    // MARK: - File Sections

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
        }
    }

    private func uncommittedSection(files: [DiffFileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Uncommitted Changes")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
                .padding(.horizontal)

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
        }
    }

    private func plainFileList(files: [DiffFileEntry]) -> some View {
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
            let preservedBranches = branches.filter { !$0.isActive }

            ScrollView {
                LazyVStack(spacing: 0) {
                    let activeBranches = branches.filter { $0.isActive && $0.sessionId != sessionId }
                    if !activeBranches.isEmpty {
                        sectionHeader("Active Sessions")
                        ForEach(activeBranches) { branch in
                            branchRow(branch)
                        }
                    }

                    if !preservedBranches.isEmpty {
                        sectionHeader("Preserved Branches")
                        ForEach(preservedBranches) { branch in
                            branchRow(branch)
                        }
                    }

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
            if worktreeStatus?.hasWorktree == true {
                unifiedHeader
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

    // MARK: - Data Loading

    private func loadAll() async {
        isLoading = true
        errorMessage = nil

        async let diffResult = rpcClient.worktree.getWorkingDirectoryDiff(sessionId: sessionId)
        async let statusResult: WorktreeGetStatusResult? = {
            try? await rpcClient.worktree.getStatus(sessionId: sessionId)
        }()
        async let committedDiffResult: CommittedDiffResult? = {
            try? await rpcClient.worktree.getCommittedDiff(sessionId: sessionId)
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
        branches = (try? await rpcClient.worktree.listSessionBranches(sessionId: sessionId)) ?? []
        isBranchesLoading = false
    }

    // MARK: - Worktree Actions

    private func commitWorktreeChanges() {
        Task {
            isCommitting = true
            defer { isCommitting = false }

            do {
                let result = try await rpcClient.worktree.commit(
                    sessionId: sessionId,
                    message: "Manual commit from iOS"
                )
                if result.success {
                    await loadAll()
                } else if let error = result.error {
                    errorMessage = "Commit failed: \(error)"
                }
            } catch {
                errorMessage = "Commit failed: \(error.localizedDescription)"
            }
        }
    }

    private func mergeWorktreeChanges() {
        Task {
            isMerging = true
            defer { isMerging = false }

            do {
                let targetBranch = worktreeStatus?.worktree?.baseBranch ?? "main"
                let mergeResult = try await rpcClient.worktree.merge(
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

    private func pruneAllBranches() {
        Task {
            isPruning = true
            defer { isPruning = false }

            do {
                let _ = try await rpcClient.worktree.pruneBranches(sessionId: sessionId)
                await loadBranches()
            } catch {
                errorMessage = "Prune failed: \(error.localizedDescription)"
            }
        }
    }
}
