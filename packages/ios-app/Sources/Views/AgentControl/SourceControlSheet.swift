import SwiftUI

// MARK: - Source Control Sheet

/// Drill-down sheet for source control details: staged/unstaged files, branches, commit/merge actions.
/// Presented from AgentControlView via the SourceControlCardView.
@available(iOS 26.0, *)
struct SourceControlSheet: View {
    let rpcClient: RPCClient
    let sessionId: String
    var initialDiffResult: WorktreeGetDiffResult?
    var initialWorktreeStatus: WorktreeGetStatusResult?
    /// Shared git workflow state (lock holder, pending merge, conflict banners,
    /// divergence). Header chips and sub-sheets read peer-session signals from
    /// here; populated by `ChatViewModel+Worktree.swift`/`+Repo.swift` handlers.
    var gitWorkflowState: GitWorkflowState?
    /// Dismisses the presenting Agent Control sheet. Invoked after the user
    /// switches to a peer session from the Parallel Sessions sub-sheet so the
    /// entire sheet stack tears down and the ChatView for the new session
    /// comes into focus.
    var onDismissParent: () -> Void = {}
    /// Invoked after every git sub-sheet (Commit/Pull/Merge/Push) is
    /// dismissed. Callers thread this up to `ChatViewModel.requestWorktreeStatus()`
    /// and `AgentControlView.loadChanges()` so user-initiated actions refresh
    /// every copy of `worktreeStatus` regardless of WebSocket event delivery.
    var onWorktreeStatusShouldRefresh: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss

    // Self-managed data state
    @State private var diffResult: WorktreeGetDiffResult?
    @State private var worktreeStatus: WorktreeGetStatusResult?

    // Git actions
    @State private var errorMessage: String?

    // Sub-sheets
    @State private var selectedFileDetail: FileDetailData?
    @State private var isReloading = false

    // Git workflow sub-sheets
    @State private var activeGitAction: GitActionSheet?
    @State private var divergence: RepoDivergence?
    @State private var repoSessionCount: Int = 0

    // Server-sourced defaults for git sub-sheets. Fetched once in `.task`;
    // fall back to hard-coded defaults if the RPC fails.
    @State private var defaultMergeStrategy: String = "merge"
    @State private var defaultSessionBranchPolicy: String = "keep"
    @State private var defaultAutoSetUpstream: Bool = true

    enum GitActionSheet: String, Identifiable {
        case commit, syncMain, finalize, push, repoSessions, conflictResolver
        var id: String { rawValue }
    }

    // MARK: - Computed Properties

    private var stagedFiles: [DiffFileEntry] {
        diffResult?.files?.filter { $0.fileStagingArea == .staged } ?? []
    }

    private var unstagedFiles: [DiffFileEntry] {
        diffResult?.files?.filter { $0.fileStagingArea == .unstaged } ?? []
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Scrollable changes content
                GeometryReader { geometry in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 16) {
                            if let info = worktreeStatus?.worktree {
                                SourceControlStatusHeader(
                                    branch: info.branch,
                                    worktreePath: info.path,
                                    divergence: divergence,
                                    lockHolder: gitWorkflowState?.lockHolder,
                                    pendingMerge: gitWorkflowState?.pendingMerge
                                )
                                .sheetSection()
                            }

                            gitActionsCard
                                .sheetSection()

                            SessionChangesSection(
                                diffResult: diffResult,
                                worktreeStatus: worktreeStatus,
                                stagedFiles: stagedFiles,
                                unstagedFiles: unstagedFiles,
                                onFileSelected: { selectedFileDetail = $0 }
                            )
                            .sheetSection()
                        }
                        .padding(.vertical)
                        .frame(width: geometry.size.width)
                    }
                    .frame(width: geometry.size.width)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Source Control", color: .tronTeal)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task {
                            isReloading = true
                            await loadData()
                            isReloading = false
                        }
                    } label: {
                        Group {
                            if isReloading {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(.tronTeal)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(TronTypography.buttonSM)
                                    .foregroundStyle(.tronTeal)
                            }
                        }
                    }
                    .disabled(isReloading)
                    SheetDismissButton(color: .tronTeal)
                }
            }
            .tronErrorAlert(message: $errorMessage)
            .task {
                // Pre-populate from parent's data, then refresh in background.
                // Run the three loaders in parallel so late-arriving pills
                // (divergence chips, Sessions tile) settle in a single batch
                // rather than popping in one at a time.
                diffResult = initialDiffResult
                worktreeStatus = initialWorktreeStatus
                async let data: Void = loadData()
                async let divergenceLoad: Void = loadDivergence()
                async let defaults: Void = loadGitDefaults()
                _ = await (data, divergenceLoad, defaults)
            }
            // Sibling-session main advances / local finalize|sync|push all
            // bump the tick — re-pull divergence chips so they stay fresh.
            .onChange(of: gitWorkflowState?.divergenceRefreshTick ?? 0) { _, _ in
                Task { await loadDivergence() }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronTeal)
        .sheet(item: $selectedFileDetail) { fileData in
            FileDetailSheet(
                file: fileData,
                stagingArea: fileData.stagingArea,
                rpcClient: rpcClient,
                sessionId: sessionId,
                onAction: {
                    Task { await loadData() }
                }
            )
            .presentationDragIndicator(.hidden)
            .adaptivePresentationDetents([.medium, .large])
        }
        .sheet(item: $activeGitAction, onDismiss: {
            Task {
                await loadData()
                await loadDivergence()
                await onWorktreeStatusShouldRefresh?()
            }
        }) { action in
            gitActionSheet(for: action)
        }
    }

    // MARK: - Git Actions Card

    /// Compact quick-action bar: one row of equal-width tiles, each a
    /// tappable colored container opening its own sub-sheet. Previously a
    /// mix of stacked rows and a separate toolbar commit button; the flat
    /// Commit / Pull / Merge / Push row (+ optional Sessions) keeps the
    /// main sheet dense and gives every git verb parity.
    private var gitActionsCard: some View {
        HStack(spacing: 8) {
            gitActionTile(
                icon: "square.and.pencil",
                title: "Commit",
                tint: .tronTeal
            ) { activeGitAction = .commit }

            gitActionTile(
                icon: "arrow.down.circle",
                title: "Pull",
                tint: .tronEmerald
            ) { activeGitAction = .syncMain }

            gitActionTile(
                icon: "checkmark.seal",
                title: "Merge",
                tint: .tronCoral
            ) { activeGitAction = .finalize }

            gitActionTile(
                icon: "arrow.up.circle",
                title: "Push",
                tint: .tronSky
            ) { activeGitAction = .push }

            if repoSessionCount > 0 {
                gitActionTile(
                    icon: "rectangle.stack.person.crop",
                    title: repoSessionCount == 1 ? "1 Session" : "\(repoSessionCount) Sessions",
                    tint: .tronAmber
                ) { activeGitAction = .repoSessions }
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
    }

    private func gitActionTile(
        icon: String,
        title: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .sectionFill(tint, subtle: true)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Git Action Sheet Router

    @ViewBuilder
    private func gitActionSheet(for action: GitActionSheet) -> some View {
        switch action {
        case .commit:
            CommitSubSheet(
                rpcClient: rpcClient,
                sessionId: sessionId,
                diffResult: diffResult,
                worktreeStatus: worktreeStatus,
                stagedFiles: stagedFiles
            )
        case .syncMain:
            SyncMainSubSheet(
                rpcClient: rpcClient,
                sessionId: sessionId
            )
        case .finalize:
            FinalizeSessionSubSheet(
                rpcClient: rpcClient,
                sessionId: sessionId,
                suggestedTargetBranch: worktreeStatus?.worktree?.baseBranch,
                defaultStrategy: defaultMergeStrategy,
                defaultSessionBranchPolicy: defaultSessionBranchPolicy,
                onConflicts: { _ in
                    activeGitAction = .conflictResolver
                }
            )
        case .push:
            PushSubSheet(
                rpcClient: rpcClient,
                sessionId: sessionId,
                currentBranch: worktreeStatus?.worktree?.branch ?? "",
                defaultAutoSetUpstream: defaultAutoSetUpstream
            )
        case .repoSessions:
            RepoSessionsSubSheet(
                rpcClient: rpcClient,
                sessionId: sessionId,
                gitWorkflowState: gitWorkflowState,
                onSelectSession: { targetSessionId in
                    // Tear down the sheet stack and route to the peer session.
                    // ContentView observes `.switchToSession` and updates
                    // `selectedSessionId`, which in turn calls
                    // `handleSessionSelection` to persist active session.
                    NotificationCenter.default.post(name: .switchToSession, object: targetSessionId)
                    activeGitAction = nil
                    dismiss()
                    onDismissParent()
                }
            )
        case .conflictResolver:
            ConflictResolverSubSheet(
                rpcClient: rpcClient,
                sessionId: sessionId,
                gitWorkflowState: gitWorkflowState
            )
        }
    }

    private func loadDivergence() async {
        // Resolve both RPCs in parallel, then flush to state once with a
        // coordinated animation so chips + Sessions tile fade in together.
        async let d = rpcClient.repo.getDivergence(sessionId: sessionId)
        async let s = rpcClient.repo.listSessions(sessionId: sessionId)
        let resolvedDivergence = try? await d
        let resolvedSessions = try? await s
        withAnimation(.easeInOut(duration: 0.25)) {
            divergence = resolvedDivergence
            if let resolvedSessions {
                repoSessionCount = max(0, resolvedSessions.count - 1)
            }
        }
    }

    /// Fetch `git.*` defaults from server settings so sub-sheets reflect the
    /// user's preferences (strategy, branch policy, upstream behavior) instead
    /// of the hard-coded fallbacks. Failure silently keeps the defaults.
    private func loadGitDefaults() async {
        guard let settings = try? await rpcClient.settings.get() else { return }
        defaultMergeStrategy = settings.gitMergeStrategy
        defaultSessionBranchPolicy = settings.gitSessionBranchPolicy
        defaultAutoSetUpstream = settings.gitAutoSetUpstream
    }

    // MARK: - Data Loading

    private func loadData() async {
        do {
            async let diff = rpcClient.worktree.getWorkingDirectoryDiff(sessionId: sessionId)
            async let status: WorktreeGetStatusResult? = { try? await rpcClient.worktree.getStatus(sessionId: sessionId) }()
            diffResult = try await diff
            worktreeStatus = await status
        } catch {
            errorMessage = "Failed to load changes: \(error.localizedDescription)"
        }
    }

}
