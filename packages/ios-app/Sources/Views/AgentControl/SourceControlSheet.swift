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
    /// Origin of a pending abort — drives the confirmation alert message
    /// and, on confirmation, the `worktree.abortMerge` call. Non-nil means
    /// the alert is visible.
    @State private var pendingAbortOrigin: ConflictOrigin?
    @State private var isAbortingConflict = false

    // Server-sourced defaults for git sub-sheets. Fetched once in `.task`;
    // fall back to hard-coded defaults if the RPC fails.
    @State private var defaultMergeStrategy: String = "merge"
    @State private var defaultSessionBranchPolicy: String = "keep"
    @State private var defaultAutoSetUpstream: Bool = true
    /// Protected branches from server settings — drives the Push tile's
    /// enabled state. `nil` means "not yet loaded from the server"; in that
    /// state Push is gated off entirely so we never authorize a push to a
    /// branch the user actually marked protected. Once `loadGitDefaults()`
    /// returns, this becomes the user's authoritative `gitProtectedBranches`.
    @State private var protectedBranches: [String]? = nil

    enum GitActionSheet: String, Identifiable {
        case commit, syncMain, finalize, push, repoSessions, conflictResolver, rebaseOnMain
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
                                    pendingMerge: gitWorkflowState?.pendingMerge,
                                    conflictBanner: gitWorkflowState?.conflictBanner,
                                    // Crash-recovered pending merges share the
                                    // same action surface as live conflicts:
                                    // open the resolver or trigger the
                                    // origin-aware abort. The resolver itself
                                    // drives `continueMerge` via the subagent
                                    // path once spawned.
                                    onContinueSubagent: {
                                        activeGitAction = .conflictResolver
                                    },
                                    onAbortPending: {
                                        // Fall back to `.finalize` when we
                                        // don't know the origin (pending_merge
                                        // events don't yet carry it). Server
                                        // dispatches abort by actual origin
                                        // from `pending_merges[sid].origin`.
                                        pendingAbortOrigin =
                                            gitWorkflowState?.conflictBanner?.origin ?? .finalize
                                    },
                                    onResolveConflicts: {
                                        activeGitAction = .conflictResolver
                                    },
                                    onAbortConflicts: {
                                        pendingAbortOrigin = gitWorkflowState?.conflictBanner?.origin
                                    }
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
                },
                onOpenConflictResolver: {
                    selectedFileDetail = nil
                    activeGitAction = .conflictResolver
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
        .alert(
            "Abort?",
            isPresented: Binding(
                get: { pendingAbortOrigin != nil },
                set: { if !$0 { pendingAbortOrigin = nil } }
            ),
            presenting: pendingAbortOrigin
        ) { _ in
            Button("Abort", role: .destructive) {
                Task { await performAbort() }
            }
            Button("Cancel", role: .cancel) {
                pendingAbortOrigin = nil
            }
        } message: { origin in
            Text(origin.abortConfirmationMessage)
        }
    }

    // MARK: - Git Actions Card

    /// Two rows of three tiles each. Row 1 — Commit · Merge · Sessions.
    /// Row 2 — Rebase · Pull · Push. Every tile mirrors a server-side
    /// precondition for its action, so taps that would inevitably reject
    /// fade to 40% opacity and become non-interactive. The shared
    /// `isWorkflowFree` gate disables every mutation while the repo lock
    /// is held, a conflict banner is active, or a pending merge needs
    /// resolution — the conflict resolver, not this grid, is the way out
    /// of those states.
    private var gitActionsCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                gitActionTile(
                    icon: "square.and.pencil",
                    title: "Commit",
                    tint: .tronTeal,
                    isEnabled: isCommitEnabled
                ) { activeGitAction = .commit }

                gitActionTile(
                    icon: "checkmark.seal",
                    title: "Merge",
                    tint: .tronCoral,
                    isEnabled: isMergeEnabled
                ) { activeGitAction = .finalize }

                gitActionTile(
                    icon: "rectangle.stack.person.crop",
                    title: repoSessionCount == 0
                        ? "Sessions"
                        : (repoSessionCount == 1 ? "1 Session" : "\(repoSessionCount) Sessions"),
                    tint: .tronAmber,
                    isEnabled: isSessionsEnabled
                ) { activeGitAction = .repoSessions }
            }
            HStack(spacing: 8) {
                gitActionTile(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Rebase",
                    tint: .tronPurple,
                    isEnabled: isRebaseEnabled
                ) { activeGitAction = .rebaseOnMain }

                gitActionTile(
                    icon: "arrow.down.circle",
                    title: "Pull",
                    tint: .tronEmerald,
                    isEnabled: isPullEnabled
                ) { activeGitAction = .syncMain }

                gitActionTile(
                    icon: "arrow.up.circle",
                    title: "Push",
                    tint: .tronSky,
                    isEnabled: isPushEnabled
                ) { activeGitAction = .push }
            }
        }
    }

    /// Shared mutation gate: every git workflow that mutates the repo
    /// is blocked while another session holds the repo-wide lock, while
    /// this session has an active conflict banner, or while a crash-
    /// recovered pending merge still needs to be resolved or aborted.
    /// The coordinator rejects the same cases server-side — gating here
    /// avoids the round trip and an error popup.
    private var isWorkflowFree: Bool {
        gitWorkflowState?.lockHolder == nil
            && gitWorkflowState?.conflictBanner == nil
            && gitWorkflowState?.pendingMerge == nil
    }

    /// Commit tile needs uncommitted changes AND a workflow-free
    /// session. Conflict resolution goes through the dedicated
    /// conflict resolver, not this sheet.
    private var isCommitEnabled: Bool {
        guard isWorkflowFree else { return false }
        return worktreeStatus?.worktree?.hasUncommittedChanges == true
    }

    /// Merge (finalize) tile needs commits to integrate, a clean tree,
    /// and the session NOT sitting on its own base branch (nothing to
    /// merge into anything). Each condition mirrors a server-side
    /// `finalizeSession` precondition.
    private var isMergeEnabled: Bool {
        guard isWorkflowFree else { return false }
        guard let info = worktreeStatus?.worktree else { return false }
        guard !info.isOnBaseBranch else { return false }
        guard (info.commitCount ?? 0) > 0 else { return false }
        guard info.hasUncommittedChanges != true else { return false }
        return true
    }

    /// Sessions tile is purely informational — disable when there are
    /// no peer sessions to switch to (the sub-sheet would just show an
    /// empty list). `repoSessionCount` is already
    /// `max(0, listSessions.count - 1)` i.e. excludes self.
    private var isSessionsEnabled: Bool {
        repoSessionCount > 0
    }

    /// Rebase tile is enabled when the session is demonstrably behind
    /// main AND no blocking workflow state is present. Each condition
    /// mirrors a server-side `rebaseOnMain` precondition so the UI fails
    /// gracefully without a round trip.
    private var isRebaseEnabled: Bool {
        guard isWorkflowFree else { return false }
        guard (divergence?.behindMain ?? 0) > 0 else { return false }
        return true
    }

    /// Pull (syncMain) tile is enabled when local main is behind origin
    /// main AND a remote is configured AND no blocking workflow state.
    /// Strict gating: if there's nothing to pull, the tile is off —
    /// avoids no-op fetch round-trips.
    private var isPullEnabled: Bool {
        guard isWorkflowFree else { return false }
        guard divergence?.hasOrigin == true else { return false }
        guard (divergence?.behindOrigin ?? 0) > 0 else { return false }
        return true
    }

    /// Push tile is enabled when a remote is configured, the current
    /// branch is NOT in the user's protected list, and the session is
    /// workflow-free. We don't gate on commit count — pushing a zero-
    /// commit branch to set upstream is still legitimate. Until the
    /// `gitProtectedBranches` setting has loaded, Push stays disabled
    /// (we won't authorize a push without knowing the user's policy).
    private var isPushEnabled: Bool {
        guard isWorkflowFree else { return false }
        guard divergence?.hasOrigin == true else { return false }
        guard let branch = worktreeStatus?.worktree?.branch, !branch.isEmpty
        else { return false }
        guard let protected = protectedBranches else { return false }
        guard !protected.contains(branch) else { return false }
        return true
    }

    private func gitActionTile(
        icon: String,
        title: String,
        tint: Color,
        isEnabled: Bool = true,
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
        .opacity(isEnabled ? 1.0 : 0.4)
        .disabled(!isEnabled)
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
        case .rebaseOnMain:
            RebaseOnMainSubSheet(
                rpcClient: rpcClient,
                sessionId: sessionId,
                suggestedMainBranch: worktreeStatus?.worktree?.baseBranch,
                divergence: divergence,
                onConflicts: {
                    activeGitAction = .conflictResolver
                }
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

    /// Invoke `worktree.abortMerge`. The confirmation alert has already
    /// displayed the origin-specific message; the server dispatches the
    /// right abort semantics based on `pending_merges[sessionId].origin`.
    /// On success the server emits `merge_aborted` which clears
    /// `conflictBanner` via the event handler.
    private func performAbort() async {
        guard !isAbortingConflict else { return }
        isAbortingConflict = true
        defer { isAbortingConflict = false }
        do {
            _ = try await rpcClient.worktree.abortMerge(sessionId: sessionId)
            pendingAbortOrigin = nil
            // Refresh so UI reflects the post-abort state immediately
            // rather than waiting on the next event round-trip.
            await loadData()
            await loadDivergence()
            await onWorktreeStatusShouldRefresh?()
        } catch {
            errorMessage = friendlyGitError(error, action: "Abort")
            pendingAbortOrigin = nil
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
        protectedBranches = settings.gitProtectedBranches
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
