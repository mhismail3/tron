import SwiftUI

/// Complete delivery ledger retained for audit without duplicating routine
/// terminal results in the primary Activity timeline.
struct WorkerInboxAuditSheet: View {
    let workerId: String?
    let workerNames: [String: String]
    let repository: any WorkerKernelRepository

    @Environment(\.dependencies) private var dependencies

    @State private var items: [WorkerInboxItemDTO] = []
    @State private var nextOffset: UInt64?
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadGeneration = 0
    @State private var projectionOwnerId: UUID?
    @State private var selectedInboxItem: WorkerInboxSelection?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    WorkerConsoleSectionHeader(
                        title: "Delivery records",
                        detail: "Complete terminal outcomes and system records. Context status describes later agent-context attachment, not whether you opened this sheet."
                    )
                    if let error {
                        WorkerConsoleErrorBanner(message: error)
                    }
                    if items.isEmpty, !isLoading {
                        WorkerConsoleInlineEmptyState(
                            symbol: "tray",
                            text: "No delivery records have been retained."
                        )
                    } else {
                        LazyVStack(spacing: 9) {
                            ForEach(items) { item in
                                WorkerInboxCard(
                                    item: item,
                                    workerName: workerNames[item.workerId],
                                    onOpen: {
                                        selectedInboxItem = WorkerInboxSelection(
                                            item: item,
                                            workerName: workerNames[item.workerId]
                                        )
                                    }
                                )
                            }
                        }
                    }
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 12)
                    } else if nextOffset != nil {
                        Button { Task { await load(reset: false) } } label: {
                            Label("Load older delivery records", systemImage: "clock.arrow.circlepath")
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)
                        .sectionFill(.tronInfo, cornerRadius: 10, subtle: true, interactive: true)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Delivery Audit", color: .tronInfo)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronInfo)
                }
            }
            .task(id: dependencies.connectionRepository.continuity) {
                let ownerId = dependencies.connectionRepository.continuityOwnerId
                if projectionOwnerId != ownerId {
                    projectionOwnerId = ownerId
                    loadGeneration &+= 1
                    items = []
                    nextOffset = nil
                    isLoading = false
                    error = nil
                }
                guard dependencies.connectionRepository.connectionState.isConnected else { return }
                await load(reset: true)
            }
            .sheet(item: $selectedInboxItem) { selection in
                WorkerInboxDetailSheet(selection: selection, repository: repository)
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronInfo)
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }
        do {
            let page = try await repository.workerInbox(
                workerId: workerId,
                limit: 20,
                offset: reset ? nil : nextOffset,
                attentionOnly: false
            )
            guard !Task.isCancelled,
                  generation == loadGeneration else { return }
            if reset {
                items = page.items
            } else {
                var identifiers = Set(items.map(\.inboxId))
                items.append(contentsOf: page.items.filter {
                    identifiers.insert($0.inboxId).inserted
                })
            }
            nextOffset = page.nextOffset
            error = nil
        } catch {
            guard generation == loadGeneration else { return }
            if !ConnectionErrorClassifier.isTransientTransport(error) {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Canonical detail destination for a durable worker invocation.
struct WorkerRunDetailSheet: View {
    let run: WorkerInvocationDTO
    var workerName: String?
    var onCancel: (() -> Void)?

    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var currentRun: WorkerInvocationDTO
    @State private var graph: WorkerRunGraphDTO?
    @State private var selectedResult: WorkerResultSelection?
    @State private var showTechnicalDetails = false
    @State private var showExecutionDetails = false
    @State private var showAuditSession = false
    @State private var confirmCancel = false
    @State private var isMutating = false
    @State private var loadError: String?
    @State private var refreshRevision = 0
    @State private var projectionOwnerId: UUID?

    init(
        run: WorkerInvocationDTO,
        workerName: String? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.run = run
        self.workerName = workerName
        self.onCancel = onCancel
        _currentRun = State(initialValue: run)
    }

    private var color: Color {
        WorkerRunGraphPresentation.color(status: graph?.status ?? currentRun.status)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    WorkerRunInvocationSummaryView(run: currentRun)
                    if let loadError {
                        WorkerConsoleErrorBanner(message: loadError)
                    }
                    WorkerRunInvocationResultView(run: currentRun) {
                        selectedResult = WorkerResultSelection(
                            invocationId: currentRun.invocationId
                        )
                    }
                    if WorkerRunGraphPresentation.canInspectResult(status: currentRun.status) {
                        WorkerResultAgentHandoffCard(
                            invocationId: currentRun.invocationId,
                            workerName: WorkerRunGraphPresentation.runTitle(
                                workerName: graph?.workerName ?? workerName,
                                workerId: currentRun.workerId
                            )
                        ) {
                            dismiss()
                        }
                    }
                    WorkerRunInvocationExecutionOverviewView(isReady: graph != nil) {
                        guard graph != nil else { return }
                        showExecutionDetails = true
                    }
                    if let graph {
                        WorkerRunDeclarativePresentationView(
                            graph: graph,
                            repository: dependencies.workerKernelRepository
                        )
                        WorkerRunActionBar(
                            graph: graph,
                            isMutating: isMutating
                                || !dependencies.connectionRepository.connectionState.isConnected,
                            detach: { mutate(.detach) },
                            awaitResult: { mutate(.awaitResult) },
                            cancel: { confirmCancel = true },
                            retry: { mutate(.retry) }
                        )
                    }
                    technicalControls
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(
                        title: WorkerRunGraphPresentation.runTitle(
                            workerName: graph?.workerName ?? workerName,
                            workerId: currentRun.workerId
                        ),
                        color: color
                    )
                }
                if currentRun.agentSessionId?.isEmpty == false {
                    ToolbarItem(placement: .topBarLeading) {
                        LoadingToolbarButton(
                            label: "Open Chat",
                            icon: "text.bubble",
                            color: .tronEmerald,
                            isLoading: false,
                            isEnabled: true
                        ) {
                            showAuditSession = true
                        }
                        .accessibilityLabel("Open worker session")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: color)
                }
            }
            .sheet(item: $selectedResult) { selection in
                WorkerResultInspectorSheet(
                    invocationId: selection.invocationId,
                    repository: dependencies.workerKernelRepository,
                    showsTechnicalDetails: false,
                    showsOverview: false
                )
            }
            .sheet(isPresented: $showExecutionDetails) {
                if let graph {
                    WorkerRunExecutionSheet(graph: graph)
                }
            }
            .sheet(isPresented: $showAuditSession) {
                if let sessionId = currentRun.agentSessionId,
                   !sessionId.isEmpty {
                    WorkerAuditSessionSheet(sessionId: sessionId)
                }
            }
            .sheet(isPresented: $showTechnicalDetails) {
                WorkerRunTechnicalDetailsSheet(
                    run: currentRun,
                    graph: graph,
                    initialResultChunk: nil
                )
            }
            .confirmationDialog(
                "Cancel this worker run?",
                isPresented: $confirmCancel,
                titleVisibility: .visible
            ) {
                Button("Cancel run", role: .destructive) { mutate(.cancel) }
                Button("Keep running", role: .cancel) {}
            } message: {
                Text("Only this invocation will stop. Other work and the worker route remain active.")
            }
            .task(id: WorkerRunDetailRefreshKey(
                invocationId: currentRun.invocationId,
                refreshRevision: refreshRevision,
                isCovered: isPresentingChildSheet,
                continuity: dependencies.connectionRepository.continuity
            )) {
                let ownerId = dependencies.connectionRepository.continuityOwnerId
                if let projectionOwnerId, projectionOwnerId != ownerId {
                    dismiss()
                    return
                }
                projectionOwnerId = ownerId
                guard !isPresentingChildSheet else { return }
                await observeRun()
            }
            .onReceive(NotificationCenter.default.publisher(for: .workerRunProjectionInvalidated)) { _ in
                if !isPresentingChildSheet,
                   WorkerRunGraphPresentation.shouldRefreshAfterInvalidation(
                    status: graph?.status
                   ) {
                    refreshRevision += 1
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(color)
    }

    private var isPresentingChildSheet: Bool {
        selectedResult != nil
            || showExecutionDetails
            || showTechnicalDetails
            || showAuditSession
    }

    private var technicalControls: some View {
        WorkerConsoleActionCard(
            title: "Open technical details",
            detail: "Inspect raw input and result, identifiers, timing, and durability evidence.",
            symbol: "wrench.and.screwdriver",
            accent: .tronSlate
        ) {
            showTechnicalDetails = true
        }
    }

    private func observeRun() async {
        repeat {
            await refreshGraph()
            guard !Task.isCancelled else {
                return
            }
            if let graph,
               !WorkerRunGraphPresentation.isActive(status: graph.status) {
                return
            }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        } while !Task.isCancelled
    }

    private func refreshGraph() async {
        do {
            let result = try await dependencies.workerKernelRepository.workerRunGraph(
                invocationId: currentRun.invocationId,
                modelToolInvocationId: nil
            )
            guard !Task.isCancelled else { return }
            if let refreshed = result.runs.first {
                currentRun = refreshed
            }
            let refreshedGraph = result.graphs?.first
            graph = refreshedGraph
            loadError = refreshedGraph == nil
                ? "The durable run graph is not available yet."
                : nil
        } catch {
            if ConnectionErrorClassifier.isTransientTransport(error) {
                return
            }
            loadError = "Live worker state could not load: \(error.localizedDescription)"
        }
    }

    private enum Mutation {
        case detach
        case awaitResult
        case cancel
        case retry
    }

    private func mutate(_ mutation: Mutation) {
        guard dependencies.connectionRepository.connectionState.isConnected,
              !isMutating else { return }
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                switch mutation {
                case .detach:
                    currentRun = try await dependencies.workerKernelRepository.detachWorkerInvocation(
                        invocationId: currentRun.invocationId,
                        idempotencyKey: .userAction("detach-worker")
                    )
                case .awaitResult:
                    currentRun = try await dependencies.workerKernelRepository.awaitWorkerInvocation(
                        invocationId: currentRun.invocationId,
                        timeoutSeconds: 10
                    ).invocation
                case .cancel:
                    currentRun = try await dependencies.workerKernelRepository.cancelWorkerInvocation(
                        invocationId: currentRun.invocationId,
                        idempotencyKey: .userAction("cancel-worker")
                    )
                    onCancel?()
                case .retry:
                    currentRun = try await dependencies.workerKernelRepository.retryWorkerInvocation(
                        invocationId: currentRun.invocationId,
                        idempotencyKey: .userAction("retry-worker")
                    )
                }
                loadError = nil
                await refreshGraph()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

private struct WorkerRunDetailRefreshKey: Equatable {
    let invocationId: String
    let refreshRevision: Int
    let isCovered: Bool
    let continuity: EngineConnectionContinuity
}

/// Read-only presentation for a worker child session or the originating chat.
struct WorkerAuditSessionSheet: View {
    @Environment(\.dependencies) private var dependencies
    let sessionId: String
    var title: String = "Worker Session"

    var body: some View {
        NavigationStack {
            ChatView(
                services: dependencies.chatSessionServices,
                sessionId: sessionId,
                presentationMode: .workerAudit,
                readOnlyTitle: title
            )
            .id(sessionId)
        }
        .workerConsoleSheetPresentation()
        .tint(.tronEmerald)
    }
}
