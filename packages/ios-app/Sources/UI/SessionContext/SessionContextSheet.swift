import SwiftUI

struct SessionContextSheet: View {
    let sessionId: String
    let contextState: ContextTrackingState
    let currentModelId: String
    let currentModelInfo: ModelInfo?
    let reasoningLevel: String?
    let isConnected: Bool
    let isAgentActive: Bool
    let isCompacting: Bool
    let isFork: Bool
    let modelRepository: any ModelRepository
    let sessionRepository: any NetworkSessionRepository
    let workerRepository: any WorkerKernelRepository
    let cachedProviderRequestEvents: [RawEvent]
    let onSelectModel: (ModelInfo) -> Void
    let onFork: () async throws -> String

    @Environment(\.dismiss) var dismiss
    @State var availableModels: [ModelInfo] = []
    @State var isLoadingModels = false
    @State var isForking = false
    @State var showModelPicker = false
    @State var showForkConfirmation = false
    @State var sessionWorkerRuns: [WorkerInvocationDTO] = []
    @State var workerNames: [String: String] = [:]
    @State var workerRunsNextOffset: UInt64?
    @State var isLoadingWorkerRuns = false
    @State var workerLoadError: String?
    @State var selectedWorkerRun: WorkerInvocationDTO?
    @State var errorMessage: String?
    @State var workerRefreshRevision = 0
    @State var contextRequests: [SessionContextRequestSummaryDTO] = []
    @State var contextRequestsNextSequence: Int64?
    @State var latestContextDetail: SessionContextRequestDetailDTO?
    @State var isLoadingInspectableContext = false
    @State var contextLoadError: String?
    @State var agentUpdates: [SessionAgentUpdateDTO] = []
    @State var agentWaits: [SessionAgentWaitDTO] = []
    @State var agentUpdatesLoadError: String?
    @State var isLoadingAgentUpdates = false
    @State var showDeliveryHistory = false
    @State var selectedContextDetail: SessionContextDetailSelection?
    @State var showContextHistory = false

    var percentage: Int { contextState.contextPercentage }
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
        currentModelInfo?.formattedModelName ?? currentModelId.shortModelName
    }
    var workerRunGroups: [SessionWorkerRunGroup] {
        SessionContextPresentation.causalGroups(sessionWorkerRuns)
    }
    var latestContextSummary: SessionContextRequestSummaryDTO? {
        contextRequests.first
    }
    var manifest: SessionContextManifestDTO? {
        latestContextDetail?.contextManifest
    }
    var allSystemContributions: [ContextSystemContributionDTO] {
        (manifest?.systemContributions ?? []) + (latestContextDetail?.providerAdditions ?? [])
    }
    var requestWorkerSelections: [SessionContextWorkerSelection] {
        SessionContextPresentation.workerSelections(from: manifest?.toolSurface)
    }

    var requestFixedToolSelections: [SessionContextFixedToolSelection] {
        SessionContextPresentation.fixedToolSelections(from: manifest?.toolSurface)
    }
    var activeAgentUpdates: [SessionAgentUpdateDTO] {
        agentUpdates.filter {
            SessionContextPresentation.isActiveAgentUpdate(status: $0.status)
        }
    }
    var historicalAgentUpdates: [SessionAgentUpdateDTO] {
        agentUpdates.filter {
            !SessionContextPresentation.isActiveAgentUpdate(status: $0.status)
        }
    }
    var activeAgentWaits: [SessionAgentWaitDTO] {
        agentWaits.filter {
            SessionContextPresentation.isActiveAgentWait(status: $0.status)
        }
    }
    var historicalAgentWaits: [SessionAgentWaitDTO] {
        agentWaits.filter {
            !SessionContextPresentation.isActiveAgentWait(status: $0.status)
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
                VStack(spacing: SessionContextPresentation.sectionSpacing) {
                    sessionSummary
                    requestSummarySection
                    receivedContextSection
                    agentUpdatesSection
                    if manifest?.automaticContext.isEmpty == false {
                        automaticContextSection
                    }
                    workerActivitySection
                    sessionActionsSection
                    providerAuditSection

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
            }
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
                    SheetTitle(title: "Session Context", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
        .task { await loadModels() }
        .task(id: "\(sessionId):\(isConnected):\(isAgentActive):\(workerRefreshRevision)") {
            await observeSessionWorkers()
        }
        .task(id: "\(sessionId):\(isConnected):\(isAgentActive):\(workerRefreshRevision)") {
            await observeInspectableContext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workerRunProjectionInvalidated)) { _ in
            workerRefreshRevision += 1
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                models: availableModels,
                currentModelId: currentModelId,
                readOnly: !canMutate,
                reasoningLevel: currentModelInfo?.supportsReasoning == true ? reasoningLevel : nil,
                onSelect: onSelectModel
            )
        }
        .sheet(isPresented: $showForkConfirmation) {
            ForkSessionConfirmationSheet(isFork: isFork) {
                Task { await forkSession() }
            }
        }
        .sheet(item: $selectedWorkerRun) { run in
            WorkerRunDetailSheet(
                run: run,
                workerName: workerNames[run.workerId]
            )
        }
        .sheet(item: $selectedContextDetail) { selection in
            SessionContextDetailSheet(selection: selection)
        }
        .sheet(isPresented: $showContextHistory) {
            SessionContextHistorySheet(
                requests: contextRequests,
                models: availableModels,
                hasMore: contextRequestsNextSequence != nil,
                loadMore: { await loadOlderContextRequests() },
                select: { request in
                    await selectContextRequest(request)
                }
            )
        }
        .tronErrorAlert(message: $errorMessage)
    }

}
