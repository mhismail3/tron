import SwiftUI

enum SessionContextDetailDestination: Hashable {
    case agentContext
    case technical
}

struct SessionContextSheet: View {
    @Environment(\.dependencies) var dependencies
    let sessionId: String
    let serverConnectionId: String
    let contextState: ContextTrackingState
    let currentModelId: String
    let currentModelInfo: ModelInfo?
    let reasoningLevel: String?
    let isAgentActive: Bool
    let isCompacting: Bool
    let isFork: Bool
    let modelRepository: any ModelRepository
    let sessionRepository: any NetworkSessionRepository
    let workerRepository: any WorkerKernelRepository
    let onSelectModel: (ModelInfo) -> Void
    let onSelectReasoningLevel: (String) -> Void
    let onFork: () async throws -> String

    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    @State var availableModels: [ModelInfo] = []
    @State var isLoadingModels = false
    @State var modelLoadingGeneration: UInt64 = 0
    @State var isForking = false
    @State var showModelPicker = false
    @State var showForkConfirmation = false
    @State var showTerminal = false
    @State var sessionWorkerRuns: [WorkerInvocationDTO] = []
    @State var workerNames: [String: String] = [:]
    @State var workerRunsNextOffset: UInt64?
    @State var isLoadingWorkerRuns = false
    @State var workerLoadingGeneration: UInt64?
    @State var workerLoadError: String?
    @State var errorMessage: String?
    @State var refreshCoordinator = SessionContextRefreshCoordinator()
    @State var workerCatalogRevision: UInt64 = 0
    @State var loadedWorkerCatalogRevision: UInt64?
    @State var loadOlderWorkerRunsPending = false
    @State var latestContextSummary: SessionContextRequestSummaryDTO?
    @State var latestContextDetails: [SessionContextDetailDestination: SessionContextRequestDetailDTO] = [:]
    @State var isLoadingInspectableContext = false
    @State var contextLoadingGeneration: UInt64?
    @State var contextLoadError: String?
    @State var contextDetailLoadingDestination: SessionContextDetailDestination?
    @State var contextDetailLoadingGeneration: UInt64 = 0
    @State var agentUpdates: [SessionAgentUpdateDTO] = []
    @State var agentWaits: [SessionAgentWaitDTO] = []
    @State var agentUpdatesLoadError: String?
    @State var isLoadingAgentUpdates = false
    @State var hasLoadedAgentUpdatesSnapshot = false
    @State var agentUpdatesLoadingGeneration: UInt64?
    @State var agentUpdatesLaneActivated = false
    @State var workerLaneActivated = false
    @State var showBackgroundActivity = false
    @State var showSessionWorkers = false
    @State var selectedContextDetail: SessionContextDetailSelection?

    var isConnected: Bool {
        dependencies.connectionRepository.connectionState.isConnected
    }
    var cachedSessionRepository: SessionRepository {
        dependencies.eventStoreManager.eventDB.sessions
    }

    var resolvedModelInfo: ModelInfo? {
        currentModelInfo ?? ModelInfo.matching(currentModelId, in: availableModels)
    }
    var effectiveContextWindow: Int {
        SessionContextPresentation.resolvedContextWindow(
            trackedWindow: contextState.currentContextWindow,
            modelWindow: resolvedModelInfo?.contextWindow
        )
    }
    var effectiveTokensRemaining: Int {
        max(0, effectiveContextWindow - contextState.contextWindowTokens)
    }
    var percentage: Int {
        SessionContextPresentation.contextPercentage(
            tokensUsed: contextState.contextWindowTokens,
            contextWindow: effectiveContextWindow
        )
    }
    var accent: Color { SessionContextPresentation.pressure(for: percentage).color }
    var totalSessionInputTokens: Int {
        contextState.accumulatedInputTokens + contextState.accumulatedCacheReadTokens
    }
    var canMutate: Bool {
        SessionContextPresentation.canMutate(
            isConnected: isConnected,
            isAgentActive: isAgentActive,
            isCompacting: isCompacting,
            isBusy: isForking
        )
    }
    var currentModelDisplayName: String {
        resolvedModelInfo?.formattedModelName ?? currentModelId.shortModelName
    }
    var workerRunGroups: [SessionWorkerRunGroup] {
        SessionContextPresentation.causalGroups(sessionWorkerRuns)
    }
    var activeAgentUpdates: [SessionAgentUpdateDTO] {
        agentUpdates.filter {
            SessionContextPresentation.isActiveAgentUpdate(status: $0.status)
        }
    }
    var activeAgentWaits: [SessionAgentWaitDTO] {
        agentWaits.filter {
            SessionContextPresentation.isActiveAgentWait(status: $0.status)
        }
    }
    var hasRunningSessionWorker: Bool {
        sessionWorkerRuns.contains { $0.status == "queued" || $0.status == "running" }
    }
    var shouldContinueObservingDeliveryState: Bool {
        SessionContextPresentation.shouldContinueObservingDeliveryState(
            isAgentActive: isAgentActive,
            hasRunningWorker: hasRunningSessionWorker,
            updates: agentUpdates.map {
                (status: $0.status, wakePolicy: $0.wakePolicy)
            },
            waitStatuses: agentWaits.map(\.status)
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: SessionContextPresentation.sectionSpacing) {
                    sessionSummary
                    managementRows

                    if let reason = SessionContextPresentation.mutationUnavailableReason(
                        isConnected: isConnected,
                        isAgentActive: isAgentActive,
                        isCompacting: isCompacting
                    ) {
                        Text(reason)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .containerRelativeFrame(.horizontal)
                .clipped()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    LoadingToolbarButton(
                        label: currentModelId.shortModelName,
                        icon: "cpu",
                        color: ModelPickerPresentation.primaryAccent,
                        isLoading: isLoadingModels,
                        isEnabled: canMutate && !availableModels.isEmpty
                    ) {
                        showModelPicker = true
                    }
                    .accessibilityLabel("Model, \(currentModelDisplayName)")
                }
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: SessionContextPresentation.sheetTitle, color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
        .task(id: dependencies.connectionRepository.continuity) {
            await loadModels()
        }
        .task(id: SessionContextContinuityKey(
            serverConnectionId: serverConnectionId,
            sessionId: sessionId,
            continuity: dependencies.connectionRepository.continuity
        )) {
            await observeSessionContext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workerRunProjectionInvalidated)) {
            notification in
            if WorkerProjectionInvalidation.affectsSession(
                notificationObject: notification.object,
                sessionId: sessionId
            ), workerLaneActivated {
                requestWorkerRefresh()
                if agentUpdatesLaneActivated {
                    requestAgentUpdatesRefresh()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .workerLifecycleProjectionInvalidated)) {
            _ in
            workerCatalogRevision &+= 1
            if workerLaneActivated {
                requestWorkerRefresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                requestActivatedSessionContextRefreshes()
            }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                models: availableModels,
                currentModelId: currentModelId,
                readOnly: !canMutate,
                reasoningLevel: resolvedModelInfo?.supportsReasoning == true ? reasoningLevel : nil,
                onSelect: onSelectModel,
                onSelectReasoning: onSelectReasoningLevel
            )
        }
        .sheet(isPresented: $showForkConfirmation) {
            ForkSessionConfirmationSheet(isFork: isFork) {
                Task { await forkSession() }
            }
        }
        .sheet(isPresented: $showTerminal) {
            TerminalSessionSheet(
                sessionId: sessionId,
                repository: dependencies.terminalRepository
            )
        }
        .sheet(isPresented: $showBackgroundActivity) {
            SessionContextBackgroundActivitySheet(
                waits: agentWaits,
                updates: agentUpdates,
                loadError: agentUpdatesLoadError,
                isLoading: isLoadingAgentUpdates,
                hasLoadedSnapshot: hasLoadedAgentUpdatesSnapshot,
                workerRepository: workerRepository,
                onRetry: { requestAgentUpdatesRefresh() }
            )
        }
        .sheet(isPresented: $showSessionWorkers) {
            SessionContextWorkersSheet(
                runs: sessionWorkerRuns,
                workerNames: workerNames,
                nextOffset: workerRunsNextOffset,
                isLoading: isLoadingWorkerRuns,
                loadError: workerLoadError,
                onRetry: { requestWorkerRefresh() },
                onLoadOlder: { loadOlderSessionWorkerRuns() }
            )
        }
        .sheet(item: $selectedContextDetail) { selection in
            SessionContextDetailSheet(selection: selection, models: availableModels)
        }
        .tronErrorAlert(message: $errorMessage)
    }

}

private struct SessionContextContinuityKey: Equatable {
    let serverConnectionId: String
    let sessionId: String
    let continuity: EngineConnectionContinuity
}
