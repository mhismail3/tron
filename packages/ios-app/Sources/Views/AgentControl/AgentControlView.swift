import SwiftUI

// MARK: - Agent Control View

@available(iOS 26.0, *)
struct AgentControlView: View {
    let rpcClient: RPCClient
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

    // MARK: - Session State

    @State private var diffResult: WorktreeGetDiffResult?
    @State private var worktreeStatus: WorktreeGetStatusResult?
    @State private var branches: [SessionBranchInfo] = []
    @State private var sessionEvents: [SessionEvent] = []

    // (sub-sheets managed via showSourceControl / showAnalytics / showHistory)

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

    private var analytics: ConsolidatedAnalytics {
        ConsolidatedAnalytics(from: sessionEvents)
    }

    private var hasEvents: Bool {
        !sessionEvents.isEmpty
    }

    private var filteredEvents: [SessionEvent] {
        sessionEvents.filter { event in
            switch event.eventType {
            case .streamTurnStart, .streamTurnEnd, .streamTextDelta,
                 .streamThinkingDelta, .streamThinkingComplete, .compactBoundary:
                return false
            default:
                return true
            }
        }
    }

    private var analyticsTotalTokens: Int {
        let bd = analytics.costBreakdown
        return bd.baseInputTokens + bd.outputTokens + bd.cacheReadTokens
            + bd.cacheWrite5mTokens + bd.cacheWrite1hTokens + bd.cacheWriteLegacyTokens
    }

    private var turnGroups: [TurnGroup] {
        TurnGrouping.group(
            events: filteredEvents,
            analytics: analytics,
            currentSessionId: sessionId
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                contentView

                if isLoading && detailedSnapshot == nil && diffResult == nil && sessionEvents.isEmpty {
                    Color.clear
                        .background(.ultraThinMaterial)
                        .overlay {
                            ProgressView()
                                .tint(.tronEmerald)
                        }
                        .ignoresSafeArea()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Agent Control")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
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
                        rpcClient: rpcClient,
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
                    rpcClient: rpcClient,
                    sessionId: sessionId,
                    diffResult: diffResult,
                    worktreeStatus: worktreeStatus,
                    branches: branches,
                    onAskAgent: { message in
                        showSourceControl = false
                        dismiss()
                        onAskAgent?(message)
                    },
                    onReload: {
                        await loadChanges()
                        await loadBranches()
                    }
                )
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
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
                analytics: analytics,
                turnGroups: turnGroups
            )
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet(
                turnGroups: turnGroups,
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
                VStack(spacing: 16) {
                    // Context gauge
                    if let snapshot = detailedSnapshot {
                        ContextUsageGaugeView(
                            currentTokens: snapshot.currentTokens,
                            contextLimit: snapshot.contextLimit,
                            usagePercent: snapshot.usagePercent,
                            thresholdLevel: snapshot.thresholdLevel,
                            onTap: {
                                showContextDetail = true
                            }
                        )
                        .padding(.horizontal)

                        ModelControlView(
                            modelInfo: currentModelInfo,
                            reasoningLevel: reasoningLevel,
                            onTap: {
                                showModelPicker = true
                            }
                        )
                        .padding(.horizontal)
                    }

                    // Source control card
                    SourceControlCardView(
                        branchName: worktreeStatus?.worktree?.shortBranch ?? diffResult?.branch,
                        totalFiles: totalFiles,
                        totalAdditions: totalAdditions,
                        totalDeletions: totalDeletions,
                        isGitRepo: diffResult?.isGitRepo,
                        isLoading: isLoading,
                        onTap: {
                            showSourceControl = true
                        }
                    )
                    .padding(.horizontal)

                    // Analytics card
                    if hasEvents {
                        AnalyticsCardView(
                            totalTokens: analyticsTotalTokens,
                            totalCost: analytics.costBreakdown.totalCost,
                            totalTurns: analytics.turns.count,
                            onTap: { showAnalytics = true }
                        )
                        .padding(.horizontal)
                    }

                    // History card
                    HistoryCardView(
                        totalTurns: turnGroups.count,
                        totalToolCalls: analytics.totalToolCalls,
                        onTap: { showHistory = true }
                    )
                    .padding(.horizontal)

                    // Session ID
                    SessionIdRow(sessionId: sessionId)
                        .padding(.horizontal)
                }
                .padding(.vertical)
                .frame(width: geometry.size.width)
            }
            .frame(width: geometry.size.width)
        }
    }

    // MARK: - Data Loading

    private func loadAll() async {
        isLoading = true
        errorMessage = nil

        async let contextTask: Void = loadContext()
        async let changesTask: Void = loadChanges()
        async let eventsTask: Void = loadEvents()
        async let branchTask: Void = loadBranches()

        _ = await (contextTask, changesTask, eventsTask, branchTask)
        isLoading = false
    }

    private func loadContext() async {
        do {
            detailedSnapshot = try await rpcClient.context.getDetailedSnapshot(sessionId: sessionId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadContextInBackground() async {
        do {
            detailedSnapshot = try await rpcClient.context.getDetailedSnapshot(sessionId: sessionId)
            pendingSkillDeletions.removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadChanges() async {
        do {
            async let diff = rpcClient.worktree.getWorkingDirectoryDiff(sessionId: sessionId)
            async let status: WorktreeGetStatusResult? = { try? await rpcClient.worktree.getStatus(sessionId: sessionId) }()
            diffResult = try await diff
            worktreeStatus = await status
        } catch {
            errorMessage = "Failed to load changes: \(error.localizedDescription)"
        }
    }

    private func loadEvents() async {
        do {
            try await eventStoreManager.syncSessionEvents(sessionId: sessionId)
            sessionEvents = try await eventStoreManager.getSessionEvents(sessionId)
        } catch {
            // Non-critical: analytics and history gracefully degrade to empty
        }
    }

    private func loadBranches() async {
        branches = (try? await rpcClient.worktree.listSessionBranches(sessionId: sessionId)) ?? []
    }

    // MARK: - Skill Management

    private func removeSkillFromContext(skillName: String) async {
        _ = withAnimation(.tronStandard) {
            pendingSkillDeletions.insert(skillName)
        }

        do {
            let result = try await rpcClient.skill.remove(sessionId: sessionId, skillName: skillName)
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
