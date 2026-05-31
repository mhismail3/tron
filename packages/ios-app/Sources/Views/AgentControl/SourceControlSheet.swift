import SwiftUI

// MARK: - Source Control Sheet

/// Drill-down sheet for source control details: staged/unstaged files, branches, commit/merge actions.
/// Presented from AgentControlView via the SourceControlCardView.
@available(iOS 26.0, *)
struct SourceControlSheet: View {
    let engineClient: EngineClient
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

    // Server-sourced defaults for git sub-sheets. Until these load, actions
    // that depend on them stay disabled rather than using Swift-owned policy.
    @State private var defaultMergeStrategy: String?
    @State private var defaultSessionBranchPolicy: String?
    @State private var defaultAutoSetUpstream: Bool?
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

    private var hasNoSessionWorktree: Bool {
        worktreeStatus.map { !$0.hasIsolatedWorktree } ?? false
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Scrollable changes content
                GeometryReader { geometry in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 16) {
                            if hasNoSessionWorktree {
                                noWorktreeContent
                                    .sheetSection()
                            } else if let info = worktreeStatus?.worktree {
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
                                    onResolve: {
                                        activeGitAction = .conflictResolver
                                    },
                                    onAbort: { origin in
                                        pendingAbortOrigin = origin
                                    }
                                )
                                .sheetSection()

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
                            } else {
                                SessionChangesSection(
                                    diffResult: diffResult,
                                    worktreeStatus: worktreeStatus,
                                    stagedFiles: stagedFiles,
                                    unstagedFiles: unstagedFiles,
                                    onFileSelected: { selectedFileDetail = $0 }
                                )
                                .sheetSection()
                            }
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
                            await loadDivergence()
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
                // Diff/status and settings can load independently. Repo
                // metadata depends on the server-reported worktree status, so
                // it runs after `loadData()` has established whether a repo
                // owner exists for this session.
                worktreeStatus = initialWorktreeStatus
                diffResult = initialWorktreeStatus?.hasIsolatedWorktree == true ? initialDiffResult : nil
                async let data: Void = loadData()
                async let defaults: Void = loadGitDefaults()
                _ = await (data, defaults)
                await loadDivergence()
            }
            // Git/worktree events bump the tick; reload both status/diff and
            // repo metadata so visible action gating follows server truth.
            .onChange(of: gitWorkflowState?.sourceControlRefreshTick ?? 0) { _, _ in
                Task {
                    await loadData()
                    await loadDivergence()
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronTeal)
        .sheet(item: $selectedFileDetail) { fileData in
            FileDetailSheet(
                file: fileData,
                stagingArea: fileData.stagingArea,
                engineClient: engineClient,
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

    private var noWorktreeContent: some View {
        GitHeroCard(
            icon: "arrow.triangle.branch",
            title: "No Session Worktree",
            description: "This session is running without a source-control worktree.",
            accent: .tronTeal
        )
    }

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
                    tile: .commit
                ) { activeGitAction = .commit }

                gitActionTile(
                    icon: "checkmark.seal",
                    title: "Merge",
                    tint: .tronCoral,
                    tile: .merge
                ) { activeGitAction = .finalize }

                gitActionTile(
                    icon: "rectangle.stack.person.crop",
                    title: repoSessionCount == 0
                        ? "Sessions"
                        : (repoSessionCount == 1 ? "1 Session" : "\(repoSessionCount) Sessions"),
                    tint: .tronAmber,
                    tile: .sessions
                ) { activeGitAction = .repoSessions }
            }
            HStack(spacing: 8) {
                gitActionTile(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Rebase",
                    tint: .tronPurple,
                    tile: .rebase
                ) { activeGitAction = .rebaseOnMain }

                gitActionTile(
                    icon: "arrow.down.circle",
                    title: "Pull",
                    tint: .tronEmerald,
                    tile: .pull
                ) { activeGitAction = .syncMain }

                gitActionTile(
                    icon: "arrow.up.circle",
                    title: "Push",
                    tint: .tronSky,
                    tile: .push
                ) { activeGitAction = .push }
            }
        }
    }

    /// Tile-enabled matrix derived from current workflow + repo state.
    /// Centralized in `GitTileGating` so the rules can be unit-tested
    /// independent of SwiftUI. Mirror of server-side preconditions —
    /// drift between server and client is the bug this exists to catch.
    private var gating: GitTileGating {
        GitTileGating(
            hasLockHolder: gitWorkflowState?.lockHolder != nil,
            hasPendingMerge: gitWorkflowState?.pendingMerge != nil,
            hasConflictBanner: gitWorkflowState?.conflictBanner != nil,
            worktree: worktreeStatus?.worktree,
            divergence: divergence,
            protectedBranches: protectedBranches,
            repoSessionCount: repoSessionCount
        )
    }

    /// Centralised tile builder. Takes the `GitTile` identifier so
    /// the builder itself can look up enable state AND the disabled
    /// reason from the shared `gating` value — single source of truth,
    /// and tooltip copy stays in sync with the enable logic.
    private func gitActionTile(
        icon: String,
        title: String,
        tint: Color,
        tile: GitTile,
        action: @escaping () -> Void
    ) -> some View {
        let g = gating
        let defaultReason = gitDefaultBlockReason(for: tile)
        let isEnabled = defaultReason == nil && g.isEnabled(tile)
        let reason = defaultReason ?? g.reason(for: tile)
        return Button(action: action) {
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
        .help(reason ?? "")
        .accessibilityHint(reason ?? "")
    }

    // MARK: - Git Action Sheet Router

    @ViewBuilder
    private func gitActionSheet(for action: GitActionSheet) -> some View {
        switch action {
        case .commit:
            CommitSubSheet(
                engineClient: engineClient,
                sessionId: sessionId,
                diffResult: diffResult,
                worktreeStatus: worktreeStatus,
                stagedFiles: stagedFiles
            )
        case .syncMain:
            PullRemoteSubSheet(
                engineClient: engineClient,
                sessionId: sessionId
            )
        case .finalize:
            if let defaultMergeStrategy, let defaultSessionBranchPolicy {
                MergeChangesSubSheet(
                    engineClient: engineClient,
                    sessionId: sessionId,
                    suggestedTargetBranch: worktreeStatus?.worktree?.baseBranch,
                    defaultStrategy: defaultMergeStrategy,
                    defaultSessionBranchPolicy: defaultSessionBranchPolicy,
                    onConflicts: { _ in
                        activeGitAction = .conflictResolver
                    }
                )
            } else {
                gitSettingsUnavailableSheet(title: "Merge Changes", accent: .tronCoral)
            }
        case .push:
            if let defaultAutoSetUpstream {
                PushSubSheet(
                    engineClient: engineClient,
                    sessionId: sessionId,
                    currentBranch: worktreeStatus?.worktree?.branch ?? "",
                    defaultAutoSetUpstream: defaultAutoSetUpstream
                )
            } else {
                gitSettingsUnavailableSheet(title: "Push Branch", accent: .tronSky)
            }
        case .repoSessions:
            RepoSessionsSubSheet(
                engineClient: engineClient,
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
                engineClient: engineClient,
                sessionId: sessionId,
                gitWorkflowState: gitWorkflowState
            )
        case .rebaseOnMain:
            RebaseOnMainSubSheet(
                engineClient: engineClient,
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
        guard worktreeStatus?.canQueryRepoMetadata == true else {
            withAnimation(.easeInOut(duration: 0.25)) {
                divergence = nil
                repoSessionCount = 0
            }
            return
        }

        do {
            async let d = engineClient.repo.getDivergence(sessionId: sessionId)
            async let s = engineClient.repo.listSessions(sessionId: sessionId)
            let (resolvedDivergence, resolvedSessions) = try await (d, s)
            withAnimation(.easeInOut(duration: 0.25)) {
                divergence = resolvedDivergence
                repoSessionCount = max(0, resolvedSessions.count - 1)
            }
        } catch {
            errorMessage = friendlyGitError(error, action: .load)
        }
    }

    private func gitDefaultBlockReason(for tile: GitTile) -> String? {
        switch tile {
        case .merge:
            if defaultMergeStrategy == nil || defaultSessionBranchPolicy == nil {
                return "Git action defaults are still loading from the server."
            }
        case .push:
            if defaultAutoSetUpstream == nil || protectedBranches == nil {
                return "Git push policy is still loading from the server."
            }
        case .commit, .sessions, .rebase, .pull:
            break
        }
        return nil
    }

    private func gitSettingsUnavailableSheet(title: String, accent: Color) -> some View {
        GitSubSheetContainer(title: title, accent: accent) {
            GitHeroCard(
                icon: "exclamationmark.triangle",
                title: "Settings unavailable",
                description: "This action needs current git settings from the server before it can run.",
                accent: accent
            )
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
            _ = try await engineClient.worktree.abortMerge(sessionId: sessionId, idempotencyKey: .userAction("worktree.abortMerge"))
            pendingAbortOrigin = nil
            // Refresh so UI reflects the post-abort state immediately
            // rather than waiting on the next event round-trip.
            await loadData()
            await loadDivergence()
            await onWorktreeStatusShouldRefresh?()
        } catch {
            errorMessage = friendlyGitError(error, action: .abort)
            pendingAbortOrigin = nil
        }
    }

    /// Fetch `git.*` defaults from server settings so sub-sheets reflect the
    /// user's preferences (strategy, branch policy, upstream behavior).
    private func loadGitDefaults() async {
        do {
            let settings = try await engineClient.settings.get()
            defaultMergeStrategy = settings.gitMergeStrategy
            defaultSessionBranchPolicy = settings.gitSessionBranchPolicy
            defaultAutoSetUpstream = settings.gitAutoSetUpstream
            protectedBranches = settings.gitProtectedBranches
        } catch {
            errorMessage = "Failed to load git settings: \(error.localizedDescription)"
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        do {
            let status = try await engineClient.worktree.getStatus(sessionId: sessionId)
            worktreeStatus = status

            guard status.hasIsolatedWorktree else {
                withAnimation(.easeInOut(duration: 0.25)) {
                    diffResult = nil
                    divergence = nil
                    repoSessionCount = 0
                }
                return
            }

            diffResult = try await engineClient.worktree.getWorkingDirectoryDiff(sessionId: sessionId)
        } catch {
            diffResult = nil
            errorMessage = friendlyGitError(error, action: .load)
        }
    }

}
