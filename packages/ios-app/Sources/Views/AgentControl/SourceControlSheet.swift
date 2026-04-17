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

    @Environment(\.dismiss) private var dismiss

    // Self-managed data state
    @State private var diffResult: WorktreeGetDiffResult?
    @State private var worktreeStatus: WorktreeGetStatusResult?

    // Git actions
    @State private var isCommitting = false
    @State private var showCommitConfirmation = false
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
        case syncMain, finalize, push, repoSessions, conflictResolver
        var id: String { rawValue }
    }

    // MARK: - Computed Properties

    private var stagedFiles: [DiffFileEntry] {
        diffResult?.files?.filter { $0.fileStagingArea == .staged } ?? []
    }

    private var unstagedFiles: [DiffFileEntry] {
        diffResult?.files?.filter { $0.fileStagingArea == .unstaged } ?? []
    }

    private var canCommit: Bool {
        SourceControlMetadata.canCommit(
            worktreeStatus: worktreeStatus,
            isLoading: isCommitting
        )
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
                ToolbarItemGroup(placement: .topBarLeading) {
                    commitButton
                }
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
                // Pre-populate from parent's data, then refresh in background
                diffResult = initialDiffResult
                worktreeStatus = initialWorktreeStatus
                await loadData()
                await loadDivergence()
                await loadGitDefaults()
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
            Task { await loadData(); await loadDivergence() }
        }) { action in
            gitActionSheet(for: action)
        }
    }

    // MARK: - Git Actions Card

    private var gitActionsCard: some View {
        VStack(spacing: 8) {
            gitActionRow(
                icon: "arrow.down.circle",
                title: "Pull Remote",
                subtitle: "Fetch all remote changes and fast-forward main",
                tint: .tronEmerald
            ) { activeGitAction = .syncMain }

            gitActionRow(
                icon: "checkmark.seal",
                title: "Merge Changes",
                subtitle: "Merge session branch and rebranch",
                tint: .tronCoral
            ) { activeGitAction = .finalize }

            gitActionRow(
                icon: "arrow.up.circle",
                title: "Push Branch",
                subtitle: "Push session branch to origin",
                tint: .tronSky
            ) { activeGitAction = .push }

            if repoSessionCount > 0 {
                gitActionRow(
                    icon: "rectangle.stack.person.crop",
                    title: "\(repoSessionCount) Parallel \(repoSessionCount == 1 ? "Session" : "Sessions")",
                    subtitle: "View and jump to sibling sessions",
                    tint: .tronAmber
                ) { activeGitAction = .repoSessions }
            }
        }
    }

    private func gitActionRow(
        icon: String,
        title: String,
        subtitle: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(subtitle)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
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
                onSelectSession: { _ in
                    activeGitAction = nil
                    dismiss()
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
        divergence = try? await rpcClient.repo.getDivergence(sessionId: sessionId)
        if let sessions = try? await rpcClient.repo.listSessions(sessionId: sessionId) {
            repoSessionCount = max(0, sessions.count - 1)
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

    // MARK: - Toolbar Buttons

    @ViewBuilder
    private var commitButton: some View {
        Button { showCommitConfirmation = true } label: {
            if isCommitting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(canCommit ? .tronTeal : .tronTextMuted.opacity(0.5))
            }
        }
        .disabled(!canCommit || isCommitting)
        .accessibilityLabel("Commit")
        .popover(isPresented: $showCommitConfirmation, arrowEdge: .top) {
            GlassActionSheet(
                actions: [
                    GlassAction(title: "Commit Changes", icon: "checkmark.circle", color: .tronTeal, role: .default) {
                        showCommitConfirmation = false
                        commitChanges()
                    },
                    GlassAction(title: "Cancel", icon: nil, color: .tronTextMuted, role: .cancel) {
                        showCommitConfirmation = false
                    }
                ]
            )
            .presentationCompactAdaptation(.popover)
        }
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

    // MARK: - Git Actions

    private func commitChanges() {
        Task {
            isCommitting = true
            defer { isCommitting = false }

            do {
                let result = try await rpcClient.worktree.commit(
                    sessionId: sessionId,
                    message: "Manual commit from iOS"
                )
                if result.success {
                    await loadData()
                } else if let error = result.error {
                    errorMessage = "Commit failed: \(error)"
                }
            } catch {
                errorMessage = "Commit failed: \(error.localizedDescription)"
            }
        }
    }

}
