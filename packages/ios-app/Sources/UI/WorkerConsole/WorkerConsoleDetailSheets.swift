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

/// Stable sheet destination for unbounded human-readable detail.
struct WorkerTextDetailSheet: View {
    let title: String
    let values: [String]
    let accent: Color

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        Text(value)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .sectionFill(accent, cornerRadius: 10, subtle: true, interactive: false)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: title, color: accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: accent)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(accent)
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
    @State private var showInput = false
    @State private var showLegacyOutput = false
    @State private var showTechnicalTimeline = false
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
                        causalTree(graph)
                        timeline(graph)
                        result(graph)
                        WorkerRunActionBar(
                            graph: graph,
                            isMutating: isMutating,
                            detach: { mutate(.detach) },
                            awaitResult: { mutate(.awaitResult) },
                            cancel: { confirmCancel = true },
                            retry: { mutate(.retry) },
                            inspectResult: {
                                selectedResult = WorkerResultSelection(
                                    invocationId: graph.requestedInvocationId
                                )
                            }
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
            .sheet(isPresented: $showInput) {
                WorkerJSONDetailSheet(
                    title: "Worker Input",
                    value: currentRun.input,
                    accent: .tronInfo
                )
            }
            .sheet(isPresented: $showLegacyOutput) {
                if let output = currentRun.output?.legacyInline {
                    WorkerJSONDetailSheet(
                        title: "Legacy Worker Result",
                        value: output,
                        accent: color
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
                refreshRevision += 1
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
                Text(reference.preview)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(color, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func causalTree(_ graph: WorkerRunGraphDTO) -> some View {
        WorkerConsoleSection(
            title: "Run tree",
            detail: "Coordinator, specialist, attempt, and model nodes ordered by the server’s causal record.",
            accent: .tronCyan
        ) {
            WorkerRunCausalTreeView(graph: graph) { sessionId in
                selectedSession = WorkerRunSessionSelection(sessionId: sessionId)
            }
        }
    }

    private func timeline(_ graph: WorkerRunGraphDTO) -> some View {
        let visible = graph.timeline.filter { !$0.technical }
        return WorkerConsoleSection(
            title: "Timeline",
            detail: "Meaningful lifecycle transitions from durable server evidence.",
            accent: .tronPurple
        ) {
            if visible.isEmpty {
                Text("No user-facing transitions have been recorded yet.")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            } else {
                WorkerRunTimelineView(entries: visible)
            }
        }
    }

    @ViewBuilder
    private func result(_ graph: WorkerRunGraphDTO) -> some View {
        if let error = graph.errorPreview, !error.isEmpty {
            WorkerConsoleSection(
                title: "Action needed",
                detail: "The terminal error reported by the durable invocation.",
                accent: .tronError
            ) {
                Text(error)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let result = graph.resultPreview, !result.isEmpty {
            WorkerConsoleSection(
                title: "Result",
                detail: "Concise terminal result. Open the typed payload for full detail.",
                accent: .tronSuccess
            ) {
                Text(result)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var technicalControls: some View {
        WorkerConsoleSection(
            title: "Technical details",
            detail: "Typed payloads, identifiers, raw technical events, and timing evidence.",
            accent: .tronSlate
        ) {
            VStack(spacing: 0) {
                detailButton("Worker input", symbol: "arrow.down.doc") { showInput = true }
                if let reference = currentRun.output?.reference {
                    WorkerMetadataDivider()
                    detailButton("Inspect typed result", symbol: "doc.text.magnifyingglass") {
                        selectedResult = WorkerResultSelection(
                            invocationId: reference.invocationId
                        )
                    }
                    WorkerMetadataDivider()
                    WorkerMetadataRow(
                        label: "Result size",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(clamping: reference.sizeBytes),
                            countStyle: .file
                        )
                    )
                    WorkerMetadataDivider()
                    WorkerMetadataRow(
                        label: "Content digest",
                        value: WorkerConsolePresentation.compactIdentifier(
                            reference.contentSha256,
                            length: 16
                        ),
                        isCode: true
                    )
                } else if currentRun.output?.legacyInline != nil {
                    WorkerMetadataDivider()
                    detailButton("Legacy result evidence", symbol: "doc.text") {
                        showLegacyOutput = true
                    }
                }
                if !technicalTimelineValues.isEmpty {
                    WorkerMetadataDivider()
                    detailButton("Technical timeline", symbol: "terminal") {
                        showTechnicalTimeline = true
                    }
                }
                WorkerMetadataDivider()
                WorkerMetadataRow(
                    label: "Invocation",
                    value: WorkerConsolePresentation.compactIdentifier(
                        currentRun.invocationId,
                        length: 18
                    ),
                    isCode: true
                )
                WorkerMetadataDivider()
                WorkerMetadataRow(
                    label: "Version",
                    value: WorkerConsolePresentation.compactIdentifier(
                        currentRun.workerVersion,
                        length: 12
                    ),
                    isCode: true
                )
                if let graph {
                    WorkerMetadataDivider()
                    WorkerMetadataRow(
                        label: "Critical path",
                        value: WorkerRunGraphPresentation.elapsed(graph.timing.criticalPathMs)
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

    private func detailButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
            }
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
            .foregroundStyle(.tronTextPrimary)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var technicalTimelineValues: [String] {
        graph?.timeline
            .filter(\.technical)
            .map {
                let timestamp = WorkerConsolePresentation.timestamp($0.occurredAt) ?? $0.occurredAt
                return "\(timestamp) · \($0.summary)"
            } ?? []
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
