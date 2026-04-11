import SwiftUI

// MARK: - Session Sheet

/// Unified session sheet combining changes, analytics, and turn-based history.
/// Replaces the separate Source Control and Session History sheets.
@available(iOS 26.0, *)
struct SessionSheet: View {
    let rpcClient: RPCClient
    let sessionId: String
    let onAskAgent: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) var dependencies

    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }

    // MARK: - State

    // Changes
    @State private var diffResult: WorktreeGetDiffResult?
    @State private var worktreeStatus: WorktreeGetStatusResult?
    @State private var branches: [SessionBranchInfo] = []

    // Events (for analytics + history)
    @State private var sessionEvents: [SessionEvent] = []

    // Loading
    @State private var isLoading = true

    // Git actions
    @State private var isCommitting = false
    @State private var isMerging = false
    @State private var showCommitConfirmation = false
    @State private var showMergeConfirmation = false

    // Sub-sheets
    @State private var selectedFileDetail: FileDetailData?
    @State private var selectedTurnGroup: TurnGroup?
    @State private var showAllBranches = false

    // Errors
    @State private var errorMessage: String?

    // MARK: - Computed Properties

    private var stagedFiles: [DiffFileEntry] {
        diffResult?.files?.filter { $0.fileStagingArea == .staged } ?? []
    }

    private var unstagedFiles: [DiffFileEntry] {
        diffResult?.files?.filter { $0.fileStagingArea == .unstaged } ?? []
    }

    private var analytics: ConsolidatedAnalytics {
        ConsolidatedAnalytics(from: sessionEvents)
    }

    private var hasEvents: Bool {
        !sessionEvents.isEmpty
    }

    /// Events filtered to remove streaming noise
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

    private var turnGroups: [TurnGroup] {
        TurnGrouping.group(
            events: filteredEvents,
            analytics: analytics,
            currentSessionId: sessionId
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

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                contentView

                if isLoading && diffResult == nil && sessionEvents.isEmpty {
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
                ToolbarItemGroup(placement: .topBarLeading) {
                    if worktreeStatus?.hasWorktree == true {
                        commitButton
                        mergeButton
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Session")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await loadAll() }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        // Sub-sheets
        .sheet(item: $selectedFileDetail) { fileData in
            FileDetailSheet(
                file: fileData,
                stagingArea: fileData.stagingArea,
                rpcClient: rpcClient,
                sessionId: sessionId,
                onAction: {
                    Task { await loadChanges() }
                }
            )
            .presentationDragIndicator(.hidden)
            .adaptivePresentationDetents([.medium, .large])
        }
        .sheet(item: $selectedTurnGroup) { turn in
            TurnDetailSheet(
                turnGroup: turn,
                sessionId: sessionId,
                eventStoreManager: eventStoreManager,
                onDismissParent: { dismiss() }
            )
            .presentationDragIndicator(.hidden)
            .adaptivePresentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAllBranches, onDismiss: {
            Task { await loadBranches() }
        }) {
            AllBranchesSheet(
                rpcClient: rpcClient,
                sessionId: sessionId,
                initialBranches: branches,
                onAskAgent: { message in
                    showAllBranches = false
                    dismiss()
                    onAskAgent?(message)
                }
            )
        }
    }

    // MARK: - Content

    private var contentView: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    // Session ID
                    SessionIdRow(sessionId: sessionId)
                        .padding(.horizontal)

                    // Changes section
                    SessionChangesSection(
                        diffResult: diffResult,
                        worktreeStatus: worktreeStatus,
                        stagedFiles: stagedFiles,
                        unstagedFiles: unstagedFiles,
                        branches: branches,
                        onFileSelected: { selectedFileDetail = $0 },
                        onShowAllBranches: { showAllBranches = true }
                    )
                    .padding(.horizontal)

                    // Analytics section
                    if hasEvents {
                        SessionAnalyticsSection(analytics: analytics)
                            .padding(.horizontal)
                    }

                    // History section
                    SessionHistorySection(
                        turnGroups: turnGroups,
                        onTurnSelected: { selectedTurnGroup = $0 }
                    )
                    .padding(.horizontal)
                }
                .padding(.vertical)
                .frame(width: geometry.size.width)
            }
            .refreshable { await loadAll() }
            .frame(width: geometry.size.width)
        }
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
                    .foregroundStyle(canCommit ? .tronEmerald : .tronTextMuted.opacity(0.5))
            }
        }
        .disabled(!canCommit || isCommitting)
        .accessibilityLabel("Commit")
        .popover(isPresented: $showCommitConfirmation, arrowEdge: .top) {
            GlassActionSheet(
                actions: [
                    GlassAction(title: "Commit Changes", icon: "checkmark.circle", color: .tronEmerald, role: .default) {
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

    @ViewBuilder
    private var mergeButton: some View {
        Button { showMergeConfirmation = true } label: {
            if isMerging {
                ProgressView().controlSize(.small)
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
                        mergeChanges()
                    },
                    GlassAction(title: "Cancel", icon: nil, color: .tronTextMuted, role: .cancel) {
                        showMergeConfirmation = false
                    }
                ]
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: - Data Loading

    private func loadAll() async {
        isLoading = true
        errorMessage = nil

        async let diffTask: Void = loadChanges()
        async let eventsTask: Void = loadEvents()
        async let branchTask: Void = loadBranches()

        _ = await (diffTask, eventsTask, branchTask)
        isLoading = false
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
            sessionEvents = try eventStoreManager.getSessionEvents(sessionId)
        } catch {
            // Non-critical: analytics and history gracefully degrade to empty
        }
    }

    private func loadBranches() async {
        branches = (try? await rpcClient.worktree.listSessionBranches(sessionId: sessionId)) ?? []
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
                    await loadAll()
                } else if let error = result.error {
                    errorMessage = "Commit failed: \(error)"
                }
            } catch {
                errorMessage = "Commit failed: \(error.localizedDescription)"
            }
        }
    }

    private func mergeChanges() {
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
}
