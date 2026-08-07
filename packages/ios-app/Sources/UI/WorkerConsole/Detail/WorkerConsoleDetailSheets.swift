import SwiftUI

enum WorkerRunTranscriptDestination: Equatable {
    case workerSession(String)

    static func resolve(agentSessionId: String?) -> WorkerRunTranscriptDestination? {
        if let agentSessionId = agentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !agentSessionId.isEmpty {
            return .workerSession(agentSessionId)
        }
        return nil
    }

    var sessionId: String {
        switch self {
        case let .workerSession(sessionId):
            sessionId
        }
    }

    var title: String {
        "Worker Session"
    }

    var accessibilityLabel: String {
        "Open worker session"
    }
}

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
                                    workerName: workerNames[item.workerId]
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
        }
        .workerConsoleSheetPresentation()
        .tint(.tronInfo)
    }

    private func load(reset: Bool) async {
        guard reset || !isLoading else { return }
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
    @State private var selectedSession: WorkerRunSessionSelection?
    @State private var selectedResult: WorkerResultSelection?
    @State private var resultChunk: WorkerResultChunkDTO?
    @State private var isLoadingResult = false
    @State private var resultLoadingInvocationId: String?
    @State private var resultLoadError: String?
    @State private var showTechnicalDetails = false
    @State private var showExecutionDetails = false
    @State private var confirmCancel = false
    @State private var isMutating = false
    @State private var loadError: String?
    @State private var refreshRevision = 0
    @State private var resultLoadGeneration = 0
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
                    if let graph {
                        WorkerRunGraphSummaryView(graph: graph)
                        if let loadError {
                            WorkerConsoleErrorBanner(message: loadError)
                        }
                        WorkerRunTerminalResultView(
                            graph: graph,
                            chunk: resultChunk,
                            isLoading: isLoadingResult,
                            loadError: resultLoadError
                        ) {
                            selectedResult = WorkerResultSelection(
                                invocationId: graph.requestedInvocationId
                            )
                        }
                        WorkerRunExecutionOverviewView(graph: graph) {
                            showExecutionDetails = true
                        }
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
                    } else {
                        summaryFallback
                        if let loadError {
                            WorkerConsoleErrorBanner(message: loadError)
                        } else {
                            SheetLoadingState(label: "Loading authoritative run…", accent: color)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 18)
                        }
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
                ToolbarItemGroup(placement: .topBarLeading) {
                    if let sessionId = currentRun.agentSessionId {
                        LoadingToolbarButton(
                            label: "Open Chat",
                            icon: "text.bubble",
                            color: .tronEmerald,
                            isLoading: false,
                            isEnabled: true
                        ) {
                            selectedSession = WorkerRunSessionSelection(sessionId: sessionId)
                        }
                        .accessibilityLabel("Open worker session")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: color)
                }
            }
            .sheet(item: $selectedSession) { selection in
                WorkerAuditSessionSheet(
                    sessionId: selection.sessionId,
                    title: "Worker Session"
                )
            }
            .sheet(item: $selectedResult) { selection in
                WorkerResultInspectorSheet(
                    invocationId: selection.invocationId,
                    repository: dependencies.workerKernelRepository,
                    showsTechnicalDetails: false
                )
            }
            .sheet(isPresented: $showExecutionDetails) {
                if let graph {
                    WorkerRunExecutionSheet(graph: graph)
                }
            }
            .sheet(isPresented: $showTechnicalDetails) {
                WorkerRunTechnicalDetailsSheet(
                    run: currentRun,
                    graph: graph,
                    initialResultChunk: resultChunk
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

    private var summaryFallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: WorkerRunGraphPresentation.symbol(status: currentRun.status))
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(workerName ?? WorkerConsolePresentation.displayLabel(currentRun.workerId))
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(WorkerConsolePresentation.runSummary(currentRun) ?? "Loading durable execution details.")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                }
            }
            if let error = currentRun.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
            } else if let reference = currentRun.output?.reference,
                      !reference.preview.isEmpty {
                Text(WorkerRunGraphPresentation.resultPresentation(reference.preview).summary)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(color, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var isPresentingChildSheet: Bool {
        selectedSession != nil
            || selectedResult != nil
            || showExecutionDetails
            || showTechnicalDetails
    }

    private var technicalControls: some View {
        WorkerConsoleSection(
            title: "Technical details",
            detail: "Raw input and result, identifiers, technical events, and timing evidence.",
            accent: .tronSlate
        ) {
            WorkerRunDisclosureRow(
                title: "Open technical details",
                detail: "Inspect the consolidated protocol and durability evidence.",
                symbol: "wrench.and.screwdriver",
                accent: .tronSlate
            ) {
                showTechnicalDetails = true
            }
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
            if let refreshedGraph {
                await loadResultOverview(for: refreshedGraph)
            }
        } catch {
            if ConnectionErrorClassifier.isTransientTransport(error) {
                return
            }
            loadError = "Live worker state could not load: \(error.localizedDescription)"
        }
    }

    private func loadResultOverview(for graph: WorkerRunGraphDTO) async {
        guard WorkerRunGraphPresentation.canInspectResult(status: graph.status) else {
            resultChunk = nil
            resultLoadError = nil
            isLoadingResult = false
            resultLoadingInvocationId = nil
            return
        }
        let invocationId = graph.requestedInvocationId
        guard resultChunk?.reference.invocationId != invocationId else {
            return
        }

        if resultChunk?.reference.invocationId != invocationId {
            resultChunk = nil
        }
        isLoadingResult = true
        resultLoadingInvocationId = invocationId
        resultLoadGeneration &+= 1
        let loadGeneration = resultLoadGeneration
        resultLoadError = nil
        defer {
            if resultLoadingInvocationId == invocationId,
               loadGeneration == resultLoadGeneration {
                isLoadingResult = false
                resultLoadingInvocationId = nil
            }
        }
        do {
            let loadedChunk = try await dependencies.workerKernelRepository.workerResult(
                invocationId: invocationId,
                pointer: "",
                offset: 0,
                limit: 4
            )
            guard !Task.isCancelled,
                  resultLoadingInvocationId == invocationId,
                  loadGeneration == resultLoadGeneration else { return }
            resultChunk = loadedChunk
        } catch {
            guard resultLoadingInvocationId == invocationId,
                  loadGeneration == resultLoadGeneration,
                  !ConnectionErrorClassifier.isTransientTransport(error) else {
                return
            }
            resultLoadError = error.localizedDescription
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

private struct WorkerRunSessionSelection: Identifiable {
    let sessionId: String
    var id: String { sessionId }
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
