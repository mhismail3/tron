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

    @State private var items: [WorkerInboxItemDTO] = []
    @State private var nextOffset: UInt64?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
            .task { await load(reset: true) }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronInfo)
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await repository.workerInbox(
                workerId: workerId,
                limit: 20,
                offset: reset ? nil : nextOffset,
                attentionOnly: false
            )
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
            self.error = error.localizedDescription
        }
    }
}

/// Canonical detail destination for a durable worker invocation.
struct WorkerRunDetailSheet: View {
    let run: WorkerInvocationDTO
    var workerName: String?
    var onCancel: (() -> Void)?

    @Environment(\.dependencies) private var dependencies
    @State private var currentRun: WorkerInvocationDTO
    @State private var graph: WorkerRunGraphDTO?
    @State private var selectedSession: WorkerRunSessionSelection?
    @State private var selectedResult: WorkerResultSelection?
    @State private var showTechnicalDetails = false
    @State private var showRunTree = false
    @State private var showTimeline = false
    @State private var confirmCancel = false
    @State private var isMutating = false
    @State private var loadError: String?
    @State private var refreshRevision = 0

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
                VStack(alignment: .leading, spacing: 18) {
                    if let graph {
                        WorkerRunGraphSummaryView(graph: graph)
                        if let loadError {
                            WorkerConsoleErrorBanner(message: loadError)
                        }
                        WorkerRunDetailLinksView(
                            graph: graph,
                            openTree: { showRunTree = true },
                            openTimeline: { showTimeline = true }
                        )
                        WorkerRunTerminalResultView(graph: graph) {
                            selectedResult = WorkerResultSelection(
                                invocationId: graph.requestedInvocationId
                            )
                        }
                        WorkerRunActionBar(
                            graph: graph,
                            isMutating: isMutating,
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
                            ProgressView("Loading authoritative run…")
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
                    SheetTitle(title: "Worker Run", color: color)
                }
                ToolbarItemGroup(placement: .topBarLeading) {
                    if let sessionId = currentRun.agentSessionId {
                        SheetPrimaryActionButton(
                            icon: "text.bubble",
                            accent: .tronPurple,
                            accessibilityLabel: "Open worker session"
                        ) {
                            selectedSession = WorkerRunSessionSelection(sessionId: sessionId)
                        }
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
                    repository: dependencies.workerKernelRepository
                )
            }
            .sheet(isPresented: $showRunTree) {
                if let graph {
                    WorkerRunTreeSheet(graph: graph)
                }
            }
            .sheet(isPresented: $showTimeline) {
                if let graph {
                    WorkerRunTimelineSheet(graph: graph)
                }
            }
            .sheet(isPresented: $showTechnicalDetails) {
                WorkerRunTechnicalDetailsSheet(run: currentRun, graph: graph)
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
            .task(id: "\(currentRun.invocationId):\(refreshRevision)") {
                await observeRun()
            }
            .onReceive(NotificationCenter.default.publisher(for: .workerRunProjectionInvalidated)) { _ in
                if WorkerRunGraphPresentation.shouldRefreshAfterInvalidation(
                    status: graph?.status
                ) {
                    refreshRevision += 1
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
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

    private var technicalControls: some View {
        WorkerConsoleSection(
            title: "Technical details",
            detail: "Raw input, identifiers, technical events, and timing evidence.",
            accent: .tronSlate
        ) {
            WorkerRunDisclosureRow(
                title: "Open technical details",
                detail: "Inspect raw protocol values and durable execution identifiers.",
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
            if let refreshed = result.runs.first {
                currentRun = refreshed
            }
            graph = result.graphs?.first
            loadError = graph == nil ? "The durable run graph is not available yet." : nil
        } catch {
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
        guard !isMutating else { return }
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

private struct WorkerRunTechnicalDetailsSheet: View {
    let run: WorkerInvocationDTO
    let graph: WorkerRunGraphDTO?

    @State private var showInput = false
    @State private var showLegacyOutput = false
    @State private var showTechnicalTimeline = false

    private var technicalTimelineValues: [String] {
        graph?.timeline
            .filter(\.technical)
            .map {
                let timestamp = WorkerConsolePresentation.timestamp($0.occurredAt) ?? $0.occurredAt
                return "\(timestamp) · \($0.summary)"
            } ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkerConsoleSection(
                        title: "Protocol values",
                        detail: "Raw worker values are available only on demand.",
                        accent: .tronInfo
                    ) {
                        VStack(spacing: 0) {
                            disclosure(
                                title: "Worker input",
                                detail: "Exact typed input admitted by the kernel.",
                                symbol: "arrow.down.doc"
                            ) {
                                showInput = true
                            }
                            if run.output?.legacyInline != nil {
                                WorkerMetadataDivider()
                                disclosure(
                                    title: "Legacy result evidence",
                                    detail: "Inline result retained for migration compatibility.",
                                    symbol: "doc.text"
                                ) {
                                    showLegacyOutput = true
                                }
                            }
                            if !technicalTimelineValues.isEmpty {
                                WorkerMetadataDivider()
                                disclosure(
                                    title: "Technical timeline",
                                    detail: "\(technicalTimelineValues.count) internal event summaries.",
                                    symbol: "terminal"
                                ) {
                                    showTechnicalTimeline = true
                                }
                            }
                        }
                    }

                    WorkerConsoleSection(
                        title: "Durable identity",
                        detail: "Immutable invocation and result ownership evidence.",
                        accent: .tronSlate
                    ) {
                        VStack(spacing: 0) {
                            metadata(
                                "Invocation",
                                run.invocationId,
                                length: 18
                            )
                            WorkerMetadataDivider()
                            metadata("Version", run.workerVersion, length: 12)
                            if let reference = run.output?.reference {
                                WorkerMetadataDivider()
                                WorkerMetadataRow(
                                    label: "Result size",
                                    value: ByteCountFormatter.string(
                                        fromByteCount: Int64(clamping: reference.sizeBytes),
                                        countStyle: .file
                                    )
                                )
                                WorkerMetadataDivider()
                                metadata("Content digest", reference.contentSha256, length: 16)
                            }
                            if let graph {
                                WorkerMetadataDivider()
                                WorkerMetadataRow(
                                    label: "Critical path",
                                    value: WorkerRunGraphPresentation.elapsed(
                                        graph.timing.criticalPathMs
                                    )
                                )
                                WorkerMetadataDivider()
                                WorkerMetadataRow(
                                    label: "Model time",
                                    value: WorkerRunGraphPresentation.elapsed(graph.timing.modelMs)
                                )
                            }
                        }
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Run Details", color: .tronSlate)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronSlate)
                }
            }
            .sheet(isPresented: $showInput) {
                WorkerJSONDetailSheet(
                    title: "Worker Input",
                    value: run.input,
                    accent: .tronInfo
                )
            }
            .sheet(isPresented: $showLegacyOutput) {
                if let output = run.output?.legacyInline {
                    WorkerJSONDetailSheet(
                        title: "Legacy Worker Result",
                        value: output,
                        accent: .tronSlate
                    )
                }
            }
            .sheet(isPresented: $showTechnicalTimeline) {
                WorkerTextDetailSheet(
                    title: "Technical Timeline",
                    values: technicalTimelineValues,
                    accent: .tronSlate
                )
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronSlate)
    }

    private func disclosure(
        title: String,
        detail: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        WorkerRunDisclosureRow(
            title: title,
            detail: detail,
            symbol: symbol,
            accent: .tronInfo,
            action: action
        )
    }

    private func metadata(_ label: String, _ value: String, length: Int) -> some View {
        WorkerMetadataRow(
            label: label,
            value: WorkerConsolePresentation.compactIdentifier(value, length: length),
            isCode: true
        )
    }
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
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronPurple)
    }
}
