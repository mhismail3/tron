import SwiftUI

// MARK: - Agent Control View

@available(iOS 26.0, *)
struct AgentControlView: View {
    let engineClient: EngineClient
    let sessionId: String
    var skillStore: SkillStore?
    var readOnly: Bool = false
    /// Observable context state — drives background refresh when tokens change (e.g. after compaction)
    var contextState: ContextTrackingState?
    /// Current model info (for display name, tier, etc.)
    var currentModelInfo: ModelInfo?
    /// Current reasoning level (e.g. "low", "medium", "high")
    var reasoningLevel: String?
    /// Available models for the model picker
    var availableModels: [ModelInfo] = []
    /// Current model ID string for the model picker
    var currentModelId: String = ""
    /// Callback for "Ask Agent" actions from branch management
    var onAskAgent: ((String) -> Void)?
    /// Shared git workflow state (lock holder, conflict banners, divergence).
    /// When provided, propagated into `SourceControlSheet` so header chips
    /// and sub-sheets render peer-session state.
    var gitWorkflowState: GitWorkflowState?
    /// Invoked when a source-control sub-sheet dismisses so the parent (the
    /// chat's ChatViewModel) can refresh its own `worktreeState`. We chain
    /// this alongside the local `loadChanges()` so the Agent Control card,
    /// the Source Control sheet, and the chat toolbar all see the same
    /// post-action state deterministically, without waiting on a server
    /// event that may arrive late or be dropped.
    var onWorktreeStatusShouldRefresh: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies

    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }

    // MARK: - Context State

    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var detailedSnapshot: DetailedContextSnapshotResult?
    @State private var showContextDetail = false
    @State private var showModelPicker = false
    @State private var showSourceControl = false
    @State private var showAnalytics = false
    @State private var showHistory = false
    @State private var pendingSkillDeletions: Set<String> = []
    @State private var cardsVisible = false
    @State private var isRetaining = false
    @State private var showRetainPopover = false

    // MARK: - Session State

    @State private var diffResult: WorktreeGetDiffResult?
    @State private var worktreeStatus: WorktreeGetStatusResult?
    @State private var branches: [SessionBranchInfo] = []
    @State private var sessionEvents: [SessionEvent] = []
    @State private var cachedAnalytics = ConsolidatedAnalytics(from: [])
    @State private var cachedTurnGroups: [TurnGroup] = []

    // MARK: - Session Computed Properties

    private var stagedFiles: [DiffFileEntry] {
        diffResult?.files?.filter { $0.fileStagingArea == .staged } ?? []
    }

    private var unstagedFiles: [DiffFileEntry] {
        diffResult?.files?.filter { $0.fileStagingArea == .unstaged } ?? []
    }

    private var totalFiles: Int {
        stagedFiles.count + unstagedFiles.count
    }

    private var totalAdditions: Int {
        (stagedFiles + unstagedFiles).reduce(0) { $0 + $1.additions }
    }

    private var totalDeletions: Int {
        (stagedFiles + unstagedFiles).reduce(0) { $0 + $1.deletions }
    }

    private var hasEvents: Bool {
        !sessionEvents.isEmpty
    }

    private var analyticsTotalTokens: Int {
        let bd = cachedAnalytics.costBreakdown
        return bd.baseInputTokens + bd.outputTokens + bd.cacheReadTokens
            + bd.cacheWrite5mTokens + bd.cacheWrite1hTokens + bd.cacheWriteDefaultTtlTokens
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            contentView
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Agent Control", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    retainButton
                }
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(
                    models: availableModels,
                    currentModelId: currentModelId,
                    readOnly: readOnly,
                    reasoningLevel: reasoningLevel ?? "medium",
                    onSelect: { model in
                        NotificationCenter.default.post(name: .modelPickerAction, object: model)
                    }
                )
            }
            .sheet(isPresented: $showContextDetail) {
                if let snapshot = detailedSnapshot {
                    ContextDetailView(
                        engineClient: engineClient,
                        sessionId: sessionId,
                        snapshot: snapshot,
                        skillStore: skillStore,
                        readOnly: readOnly,
                        pendingSkillDeletions: pendingSkillDeletions,
                        onRemoveSkill: { skillName in
                            Task { await removeSkillFromContext(skillName: skillName) }
                        },
                        onFetchSkillContent: { skillName in
                            guard let store = skillStore else { return nil }
                            let metadata = await store.getSkill(name: skillName, sessionId: sessionId)
                            return metadata?.content
                        }
                    )
                }
            }
            .sheet(isPresented: $showSourceControl) {
                SourceControlSheet(
                    engineClient: engineClient,
                    sessionId: sessionId,
                    initialDiffResult: diffResult,
                    initialWorktreeStatus: worktreeStatus,
                    gitWorkflowState: gitWorkflowState,
                    onDismissParent: { dismiss() },
                    onWorktreeStatusShouldRefresh: {
                        await loadChanges()
                        await onWorktreeStatusShouldRefresh?()
                    }
                )
            }
            .tronErrorAlert(message: $errorMessage)
            .task {
                await loadAll()
            }
            .onChange(of: contextState?.contextWindowTokens) {
                Task { await reloadContextInBackground() }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .sheet(isPresented: $showAnalytics) {
            AnalyticsSheet(
                analytics: cachedAnalytics,
                turnGroups: cachedTurnGroups
            )
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet(
                turnGroups: cachedTurnGroups,
                sessionId: sessionId,
                eventStoreManager: eventStoreManager,
                onDismissParent: { dismiss() }
            )
        }
    }

    // MARK: - Content

    private var contentView: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    // Context gauge
                    ContextUsageGaugeView(
                        currentTokens: detailedSnapshot?.currentTokens ?? 0,
                        contextLimit: detailedSnapshot?.contextLimit ?? 1,
                        usagePercent: detailedSnapshot?.usagePercent ?? 0,
                        thresholdLevel: detailedSnapshot?.thresholdLevel ?? "normal",
                        onTap: {
                            showContextDetail = true
                        }
                    )
                    .padding(.horizontal)
                    .cardEntrance(visible: cardsVisible, index: 0)

                    // Model control
                    ModelControlView(
                        modelInfo: currentModelInfo,
                        reasoningLevel: reasoningLevel,
                        onTap: {
                            showModelPicker = true
                        }
                    )
                    .padding(.horizontal)
                    .cardEntrance(visible: cardsVisible, index: 1)

                    // Source control card
                    SourceControlCardView(
                        branchName: worktreeStatus?.worktree?.shortBranch ?? diffResult?.branch,
                        totalFiles: totalFiles,
                        totalAdditions: totalAdditions,
                        totalDeletions: totalDeletions,
                        isGitRepo: diffResult?.isGitRepo,
                        isLoading: isLoading,
                        workspacePath: detailedSnapshot?.environment?.workingDirectory,
                        onTap: {
                            showSourceControl = true
                        }
                    )
                    .padding(.horizontal)
                    .cardEntrance(visible: cardsVisible, index: 2)

                    // Analytics card
                    AnalyticsCardView(
                        totalTokens: analyticsTotalTokens,
                        totalCost: cachedAnalytics.totalCost,
                        totalTurns: cachedAnalytics.turns.count,
                        onTap: { showAnalytics = true }
                    )
                    .padding(.horizontal)
                    .cardEntrance(visible: cardsVisible, index: 3)

                    // History card
                    HistoryCardView(
                        totalTurns: cachedTurnGroups.count,
                        totalToolCalls: cachedAnalytics.totalToolCalls,
                        onTap: { showHistory = true }
                    )
                    .padding(.horizontal)
                    .cardEntrance(visible: cardsVisible, index: 4)

                    // Session ID
                    SessionIdRow(sessionId: sessionId)
                        .padding(.horizontal)
                        .cardEntrance(visible: cardsVisible, index: 5)
                }
                .padding(.vertical, 12)
                .frame(width: geometry.size.width)
            }
            .frame(width: geometry.size.width)
        }
    }

    // MARK: - Data Loading

    private func loadAll() async {
        isLoading = true
        errorMessage = nil

        cardsVisible = true

        async let contextTask: Void = loadContext()
        async let changesTask: Void = loadChanges()
        async let eventsTask: Void = loadEvents()
        async let branchTask: Void = loadBranches()

        _ = await (contextTask, changesTask, eventsTask, branchTask)
        isLoading = false
    }

    private func loadContext() async {
        do {
            detailedSnapshot = try await engineClient.context.getDetailedSnapshot(sessionId: sessionId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadContextInBackground() async {
        do {
            detailedSnapshot = try await engineClient.context.getDetailedSnapshot(sessionId: sessionId)
            pendingSkillDeletions.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadChanges() async {
        do {
            async let diff = engineClient.worktree.getWorkingDirectoryDiff(sessionId: sessionId)
            async let status: WorktreeGetStatusResult? = { try? await engineClient.worktree.getStatus(sessionId: sessionId) }()
            diffResult = try await diff
            worktreeStatus = await status
        } catch {
            errorMessage = "Failed to load changes: \(error.localizedDescription)"
        }
    }

    private func loadEvents() async {
        do {
            try await eventStoreManager.syncSessionEvents(sessionId: sessionId)
            let events = try await eventStoreManager.getSessionEvents(sessionId)
            sessionEvents = events

            let analytics = ConsolidatedAnalytics(from: events)
            cachedAnalytics = analytics

            let filtered = events.filter { event in
                switch event.eventType {
                case .streamTurnStart, .streamTurnEnd, .streamTextDelta,
                     .streamThinkingDelta, .streamThinkingComplete, .compactBoundary:
                    return false
                default:
                    return true
                }
            }
            cachedTurnGroups = TurnGrouping.group(
                events: filtered,
                analytics: analytics,
                currentSessionId: sessionId
            )
        } catch {
            // Non-critical: analytics and history gracefully degrade to empty
        }
    }

    private func loadBranches() async {
        branches = (try? await engineClient.worktree.listSessionBranches(sessionId: sessionId)) ?? []
    }

    // MARK: - Retain Button

    private var retainButton: some View {
        LoadingToolbarButton(
            label: "Retain",
            icon: "brain",
            color: .tronPink,
            isLoading: isRetaining,
            isEnabled: !readOnly
        ) {
            showRetainPopover = true
        }
        .popover(isPresented: $showRetainPopover, arrowEdge: .top) {
            GlassActionSheet(
                actions: [
                    GlassAction(
                        title: "Retain Memory",
                        icon: "brain",
                        color: .tronPink,
                        role: .default
                    ) {
                        showRetainPopover = false
                        Task { await retainMemory() }
                    },
                    GlassAction(
                        title: "Cancel",
                        icon: nil,
                        color: .tronTextMuted,
                        role: .cancel
                    ) {
                        showRetainPopover = false
                    }
                ]
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    private func retainMemory() async {
        isRetaining = true
        do {
            _ = try await engineClient.misc.retainMemory(sessionId: sessionId, idempotencyKey: .userAction("memory.retain"))
        } catch {
            errorMessage = "Failed to retain memory: \(error.localizedDescription)"
        }
        isRetaining = false
    }

    // MARK: - Skill Management

    private func removeSkillFromContext(skillName: String) async {
        _ = withAnimation(.tronStandard) {
            pendingSkillDeletions.insert(skillName)
        }

        do {
            let result = try await engineClient.skill.remove(sessionId: sessionId, skillName: skillName, idempotencyKey: .userAction("skills.deactivate"))
            if result.success {
                await reloadContextInBackground()
            } else {
                _ = withAnimation(.tronStandard) {
                    pendingSkillDeletions.remove(skillName)
                }
                errorMessage = result.error ?? "Failed to remove skill"
            }
        } catch {
            _ = withAnimation(.tronStandard) {
                pendingSkillDeletions.remove(skillName)
            }
            errorMessage = "Failed to remove skill: \(error.localizedDescription)"
        }
    }
}
