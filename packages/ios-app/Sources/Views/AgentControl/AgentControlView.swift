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
    /// this alongside the local source-control summary refresh so the Agent
    /// Control card, the Source Control sheet, and the chat toolbar all see the same
    /// post-action state deterministically, without waiting on a server
    /// event that may arrive late or be dropped.
    var onWorktreeStatusShouldRefresh: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies

    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }

    // MARK: - Context State

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

    @State private var diffSummaryResult: WorktreeGetDiffSummaryResult?
    @State private var worktreeStatus: WorktreeGetStatusResult?
    @State private var branches: [SessionBranchInfo] = []
    @State private var sessionEvents: [SessionEvent] = []
    @State private var isLoadingSourceControl = true
    @State private var isRefreshingEvents = false
    @State private var agentSummary = AgentControlSummary.unknown
    @State private var cachedAnalytics = ConsolidatedAnalytics(from: [])
    @State private var cachedTurnGroups: [TurnGroup] = []

    // MARK: - Session Computed Properties

    private var hasEvents: Bool {
        !sessionEvents.isEmpty
    }

    private var sourceControlCardState: SourceControlCardState {
        SourceControlCardState(
            worktreeStatus: worktreeStatus,
            diffSummaryResult: diffSummaryResult,
            isLoading: isLoadingSourceControl,
            workspacePath: detailedSnapshot?.environment?.workingDirectory ?? cachedSessionInMemory?.workingDirectory
        )
    }

    private var cachedSessionInMemory: CachedSession? {
        eventStoreManager.sessions.first { $0.id == sessionId }
    }

    private var contextCurrentTokens: Int {
        detailedSnapshot?.currentTokens ?? contextState?.contextWindowTokens ?? 0
    }

    private var contextLimit: Int {
        detailedSnapshot?.contextLimit ?? contextState?.currentContextWindow ?? 0
    }

    private var contextUsagePercent: Double {
        if let percent = detailedSnapshot?.usagePercent { return percent }
        guard contextLimit > 0 else { return 0 }
        return Double(contextCurrentTokens) / Double(contextLimit)
    }

    private var contextThresholdLevel: String {
        if let level = detailedSnapshot?.thresholdLevel { return level }
        switch contextUsagePercent {
        case 0.9...: return "critical"
        case 0.75...: return "alert"
        case 0.6...: return "warning"
        default: return "normal"
        }
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
                    reasoningLevel: reasoningLevel,
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
                    initialDiffResult: nil,
                    initialWorktreeStatus: worktreeStatus,
                    gitWorkflowState: gitWorkflowState,
                    onDismissParent: { dismiss() },
                    onWorktreeStatusShouldRefresh: {
                        await loadSourceControlSummary(forceStatusRefresh: true)
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
            .onChange(of: gitWorkflowState?.sourceControlRefreshTick ?? 0) { _, _ in
                Task { await loadSourceControlSummary(forceStatusRefresh: true) }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .compactForm)
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
                        currentTokens: contextCurrentTokens,
                        contextLimit: contextLimit,
                        usagePercent: contextUsagePercent,
                        thresholdLevel: contextThresholdLevel,
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

                    if sourceControlCardState.isVisible {
                        // Source control card
                        SourceControlCardView(
                            state: sourceControlCardState,
                            onTap: {
                                showSourceControl = true
                            }
                        )
                        .padding(.horizontal)
                        .cardEntrance(visible: cardsVisible, index: 2)
                    }

                    // Analytics card
                    AnalyticsCardView(
                        totalTokens: agentSummary.totalTokens,
                        totalCost: agentSummary.totalCost,
                        totalTurns: agentSummary.totalTurns,
                        isLoading: !agentSummary.isKnown,
                        onTap: {
                            showAnalytics = true
                            Task { await refreshEventsForDetailIfNeeded() }
                        }
                    )
                    .padding(.horizontal)
                    .cardEntrance(visible: cardsVisible, index: 3)

                    // History card
                    HistoryCardView(
                        totalTurns: agentSummary.totalTurns,
                        totalCapabilityInvocations: agentSummary.totalCapabilityInvocations,
                        capabilityInvocationsKnown: agentSummary.capabilityInvocationsKnown,
                        isLoading: !agentSummary.isKnown,
                        onTap: {
                            showHistory = true
                            Task { await refreshEventsForDetailIfNeeded() }
                        }
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
        let sheetStart = Date()
        errorMessage = nil

        await seedSummaryFromCachedSession(freshness: .cached)
        seedSourceControlFromCache()
        cardsVisible = true

        async let contextTask: Void = loadContext()
        async let changesTask: Void = loadSourceControlSummary()
        async let eventsTask: Void = loadLocalEvents()
        async let summaryRefreshTask: Void = refreshSessionSummaryInBackground()
        async let branchTask: Void = loadBranches()

        _ = await (contextTask, changesTask, eventsTask, summaryRefreshTask, branchTask)
        logTiming("sheet initial load", startedAt: sheetStart)
    }

    private func loadContext() async {
        let startedAt = Date()
        do {
            detailedSnapshot = try await engineClient.context.getDetailedSnapshot(sessionId: sessionId)
            if let detailedSnapshot {
                contextState?.syncFromServerSnapshot(
                    currentTokens: detailedSnapshot.currentTokens,
                    contextLimit: detailedSnapshot.contextLimit
                )
            }
            logTiming("context snapshot", startedAt: startedAt)
        } catch {
            errorMessage = error.localizedDescription
            logTiming("context snapshot failed", startedAt: startedAt)
        }
    }

    private func reloadContextInBackground() async {
        let startedAt = Date()
        do {
            detailedSnapshot = try await engineClient.context.getDetailedSnapshot(sessionId: sessionId)
            pendingSkillDeletions.removeAll()
            logTiming("context background refresh", startedAt: startedAt)
        } catch {
            errorMessage = error.localizedDescription
            logTiming("context background refresh failed", startedAt: startedAt)
        }
    }

    private func seedSourceControlFromCache() {
        let startedAt = Date()
        if let cached = eventStoreManager.worktreeStatusCache.status(for: sessionId) {
            worktreeStatus = cached
            isLoadingSourceControl = cached.worktree?.hasUncommittedChanges == true
            logTiming("worktree cache hit", startedAt: startedAt)
        } else {
            isLoadingSourceControl = true
            logTiming("worktree cache miss", startedAt: startedAt)
        }
    }

    private func loadSourceControlSummary(forceStatusRefresh: Bool = false) async {
        let startedAt = Date()
        isLoadingSourceControl = worktreeStatus == nil || worktreeStatus?.worktree?.hasUncommittedChanges == true

        if forceStatusRefresh {
            eventStoreManager.worktreeStatusCache.invalidate(sessionId: sessionId)
            diffSummaryResult = nil
        }

        if worktreeStatus == nil || forceStatusRefresh {
            await eventStoreManager.worktreeStatusCache.ensureLoaded(sessionId: sessionId)
            worktreeStatus = eventStoreManager.worktreeStatusCache.status(for: sessionId)
        }

        guard let status = worktreeStatus else {
            isLoadingSourceControl = false
            logTiming("worktree status unavailable", startedAt: startedAt)
            return
        }

        guard status.hasSourceControlCheckout else {
            diffSummaryResult = nil
            isLoadingSourceControl = false
            logTiming("worktree no checkout", startedAt: startedAt)
            return
        }

        guard status.worktree?.hasUncommittedChanges != false else {
            diffSummaryResult = WorktreeGetDiffSummaryResult(
                isGitRepo: true,
                branch: status.worktree?.branch,
                summary: DiffFileSummary(totalFiles: 0, totalAdditions: 0, totalDeletions: 0),
                truncated: false
            )
            isLoadingSourceControl = false
            logTiming("worktree clean status", startedAt: startedAt)
            return
        }

        do {
            diffSummaryResult = try await engineClient.worktree.getWorkingDirectoryDiffSummary(sessionId: sessionId)
            isLoadingSourceControl = false
            logTiming("worktree diff summary", startedAt: startedAt)
        } catch {
            diffSummaryResult = nil
            isLoadingSourceControl = false
            errorMessage = "Failed to load changes: \(error.localizedDescription)"
            logTiming("worktree diff summary failed", startedAt: startedAt)
        }
    }

    private func loadLocalEvents() async {
        let startedAt = Date()
        do {
            let events = try await eventStoreManager.getSessionEvents(sessionId)
            await applyEventSummary(events, freshness: .cached)
            logTiming("local events read", startedAt: startedAt)
        } catch {
            // Non-critical: analytics and history gracefully degrade to empty
            logTiming("local events read failed", startedAt: startedAt)
        }
    }

    private func refreshSessionSummaryInBackground() async {
        let startedAt = Date()
        if agentSummary.isKnown {
            agentSummary = agentSummary.withFreshness(.refreshing)
        }

        await eventStoreManager.refreshSessionList()
        await seedSummaryFromCachedSession(
            freshness: sessionEvents.isEmpty ? .fresh : agentSummary.freshness
        )

        if agentSummary.freshness == .refreshing {
            agentSummary = agentSummary.withFreshness(.fresh)
        }
        logTiming("session summary refresh", startedAt: startedAt)
    }

    private func refreshEventsForDetailIfNeeded() async {
        guard !isRefreshingEvents else { return }
        isRefreshingEvents = true
        let startedAt = Date()
        if agentSummary.isKnown {
            agentSummary = agentSummary.withFreshness(.refreshing)
        }
        defer {
            isRefreshingEvents = false
            logTiming("remote event sync", startedAt: startedAt)
        }

        do {
            try await eventStoreManager.syncSessionEvents(sessionId: sessionId)
            let events = try await eventStoreManager.getSessionEvents(sessionId)
            await applyEventSummary(events, freshness: .fresh)
        } catch {
            if agentSummary.freshness == .refreshing {
                agentSummary = agentSummary.withFreshness(.cached)
            }
        }
    }

    private func loadBranches() async {
        let startedAt = Date()
        branches = (try? await engineClient.worktree.listSessionBranches(sessionId: sessionId)) ?? []
        logTiming("session branches", startedAt: startedAt)
    }

    private func seedSummaryFromCachedSession(freshness: AgentControlSummary.Freshness) async {
        let startedAt = Date()
        guard let session = await cachedSession() else {
            if !agentSummary.isKnown {
                agentSummary = .unknown
            }
            logTiming("local session summary miss", startedAt: startedAt)
            return
        }

        if sessionEvents.isEmpty {
            agentSummary = AgentControlSummary.fromSession(session, freshness: freshness)
        } else {
            agentSummary = AgentControlSummary.fromEvents(
                sessionEvents,
                analytics: cachedAnalytics,
                turnGroups: cachedTurnGroups,
                sessionSnapshot: session,
                freshness: freshness
            )
        }
        logTiming("local session summary", startedAt: startedAt)
    }

    private func applyEventSummary(
        _ events: [SessionEvent],
        freshness: AgentControlSummary.Freshness
    ) async {
        let startedAt = Date()
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
        agentSummary = AgentControlSummary.fromEvents(
            events,
            analytics: analytics,
            turnGroups: cachedTurnGroups,
            sessionSnapshot: await cachedSession(),
            freshness: freshness
        )
        logTiming("agent summary build", startedAt: startedAt)
    }

    private func cachedSession() async -> CachedSession? {
        AgentControlSummary.mergedSessionSnapshot(
            inMemory: cachedSessionInMemory,
            persisted: try? await eventStoreManager.eventDB.sessions.get(sessionId)
        )
    }

    private func logTiming(_ label: String, startedAt: Date) {
        #if DEBUG || BETA
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        logger.debug("[AgentControlLoad] \(label) \(elapsedMs)ms", category: .ui)
        #endif
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
            .popoverCompactAdaptation()
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
