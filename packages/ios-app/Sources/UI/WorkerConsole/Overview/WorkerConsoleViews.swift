import SwiftUI

enum WorkerVersionAction: Equatable {
    case rollback
    case restore

    var title: String {
        switch self {
        case .rollback: "Rollback"
        case .restore: "Restore"
        }
    }

    static func resolve(worker: WorkerSummaryDTO, version: WorkerVersionDTO) -> Self? {
        if worker.retired {
            return .restore
        }
        return version.version == worker.activeVersion ? nil : .rollback
    }
}
private enum WorkerConsolePageKind: Equatable {
    case engine
    case activity

    var title: String {
        switch self {
        case .engine: "Engine"
        case .activity: "Activity"
        }
    }

    var initialSection: WorkerConsoleDashboardSection {
        switch self {
        case .engine: .workers
        case .activity: .scheduled
        }
    }
}

private enum WorkerConsoleDashboardSection: String, CaseIterable {
    case workers = "Workers"
    case primitives = "Primitives"
    case scheduled = "Scheduled"
    case pastWork = "Past Work"
    case results = "Results"
}

private struct EngineDashboardRefreshKey: Equatable {
    let continuity: EngineConnectionContinuity
    let section: WorkerConsoleDashboardSection
    let isCovered: Bool
}

struct EngineDashboardPage: View {
    @Binding var primaryPage: TronPrimaryPage
    @Bindable var viewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository
    let actions: ShellToolbarActions

    var body: some View {
        WorkerConsolePage(
            pageKind: .engine,
            primaryPage: $primaryPage,
            viewModel: viewModel,
            repository: repository,
            actions: actions
        )
    }
}

struct WorkerActivityPage: View {
    @Binding var primaryPage: TronPrimaryPage
    @Bindable var viewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository
    let actions: ShellToolbarActions

    var body: some View {
        WorkerConsolePage(
            pageKind: .activity,
            primaryPage: $primaryPage,
            viewModel: viewModel,
            repository: repository,
            actions: actions
        )
    }
}

private struct WorkerConsolePage: View {
    @Environment(\.dependencies) private var dependencies
    let pageKind: WorkerConsolePageKind
    @Binding var primaryPage: TronPrimaryPage
    @Bindable var viewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository
    let actions: ShellToolbarActions

    @State private var selectedSection: WorkerConsoleDashboardSection
    @State private var selectedPrimitiveTool: EngineSurfaceToolDTO?
    @State private var selectedRun: WorkerInvocationDTO?
    @State private var selectedInboxItem: WorkerInboxSelection?

    private var connectionState: ConnectionState {
        dependencies.connectionRepository.connectionState
    }

    init(
        pageKind: WorkerConsolePageKind,
        primaryPage: Binding<TronPrimaryPage>,
        viewModel: WorkerConsoleViewModel,
        repository: any WorkerKernelRepository,
        actions: ShellToolbarActions
    ) {
        self.pageKind = pageKind
        _primaryPage = primaryPage
        self.viewModel = viewModel
        self.repository = repository
        self.actions = actions
        _selectedSection = State(initialValue: pageKind.initialSection)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if pageKind == .engine {
                        summaryCard
                    }
                    if !connectionState.isConnected, viewModel.hasLoaded {
                        WorkerConsoleContinuityBanner()
                    }
                    TronSegmentedControl(
                        options: availableSections.map { ($0.rawValue, $0) },
                        selection: $selectedSection,
                        accent: .tronEmerald
                    )
                    if let error = viewModel.lastError ?? viewModel.monitoringError {
                        WorkerConsoleErrorBanner(message: error)
                    }
                    dashboardContent
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ShellToolbarContent(
                    title: pageKind.title,
                    accent: .tronEmerald,
                    actions: ShellToolbarActions(
                        onSettings: actions.onSettings,
                        onRefresh: { Task { await refresh() } }
                    ),
                    primaryPage: $primaryPage
                )
            }
            .sheet(isPresented: selectedWorkerPresented) {
                if let worker = viewModel.selectedWorker {
                    switch WorkerExperienceRoute.resolve(worker) {
                    case .researchSuite:
                        ResearchSuiteSheet(
                            consoleViewModel: viewModel,
                            repository: repository
                        )
                    case .delegation:
                        DelegationSheet(
                            consoleViewModel: viewModel,
                            repository: repository
                        )
                    case .genericConsole:
                        WorkerDetailSheet(
                            viewModel: viewModel,
                            repository: repository
                        )
                    }
                } else {
                    WorkerDetailSheet(
                        viewModel: viewModel,
                        repository: repository
                    )
                }
            }
            .sheet(item: $selectedPrimitiveTool) { tool in
                EnginePrimitiveToolDetailSheet(tool: tool)
            }
            .sheet(item: $selectedRun) { run in
                WorkerRunDetailSheet(
                    run: run,
                    workerName: viewModel.workerName(for: run.workerId),
                    onCancel: (run.status == "queued" || run.status == "running") ? {
                        Task {
                            await viewModel.cancel(
                                run,
                                repository: repository,
                                connectionState: dependencies.connectionRepository.connectionState
                            )
                            selectedRun = viewModel.activityRuns.first {
                                $0.invocationId == run.invocationId
                            }
                        }
                    } : nil
                )
            }
            .sheet(item: $selectedInboxItem) { selection in
                WorkerInboxDetailSheet(
                    selection: selection,
                    repository: repository,
                    onDispositionChanged: {
                        await viewModel.refreshResults(
                            repository: repository,
                            connectionState: dependencies.connectionRepository.connectionState
                        )
                    }
                )
            }
            .task(id: EngineDashboardRefreshKey(
                continuity: dependencies.connectionRepository.continuity,
                section: selectedSection,
                isCovered: isPresentingChildSheet
            )) {
                guard !isPresentingChildSheet else { return }
                let continuity = dependencies.connectionRepository.continuity
                let isReconnect = viewModel.reconcileServerProjection(continuity)
                if isReconnect {
                    await refresh()
                } else {
                    await ensureLoaded()
                }
                if selectedSection == .pastWork {
                    await viewModel.monitor(
                        repository: repository,
                        connectionState: dependencies.connectionRepository.connectionState
                    )
                } else if selectedSection == .results {
                    await viewModel.monitorResults(
                        repository: repository,
                        connectionState: dependencies.connectionRepository.connectionState
                    )
                } else if selectedSection == .scheduled {
                    await viewModel.monitorScheduled(
                        repository: repository,
                        connectionState: dependencies.connectionRepository.connectionState
                    )
                } else {
                    await viewModel.monitorSummary(
                        repository: repository,
                        connectionState: dependencies.connectionRepository.connectionState
                    )
                }
            }
        }
        .tronScreenBackground()
        .tint(.tronEmerald)
    }

    private var scheduledContent: some View {
        WorkerConsoleGroup(
            title: "Upcoming work",
            detail: "Enabled recurring schedules and future runs already admitted to the durable queue."
        ) {
            if !connectionState.isConnected, viewModel.scheduledWork.isEmpty {
                WorkerConsoleInlineEmptyState(
                    symbol: "network.slash",
                    text: "Reconnect to inspect upcoming work."
                )
            } else if !viewModel.hasLoadedScheduled && viewModel.isRefreshing {
                WorkerConsoleLoadingState(title: "Loading scheduled work")
            } else if viewModel.scheduledWork.isEmpty {
                WorkerConsoleInlineEmptyState(
                    symbol: "calendar.badge.clock",
                    text: "No upcoming worker executions are scheduled."
                )
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(viewModel.scheduledWork) { item in
                        ScheduledWorkerCard(item: item) {
                            Task { await viewModel.select(item.workerId, repository: repository) }
                        }
                    }
                }
                if viewModel.scheduledWorkNextOffset != nil {
                    scheduledLoadMoreButton("Load more scheduled work") {
                        await viewModel.loadOlderScheduledWork(repository: repository)
                    }
                }
            }
        }
    }

    private var availableSections: [WorkerConsoleDashboardSection] {
        switch pageKind {
        case .engine: [.workers, .primitives]
        case .activity: [.scheduled, .pastWork, .results]
        }
    }

    @ViewBuilder
    private var dashboardContent: some View {
        switch selectedSection {
        case .primitives:
            primitiveContent
        case .workers:
            workersContent
        case .scheduled:
            scheduledContent
        case .pastWork:
            activityContent
        case .results:
            resultsContent
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: consoleStatus.symbol)
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(consoleStatus.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(consoleStatus.title)
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(consoleStatus.detail)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                summaryMetric(value: viewModel.primitiveToolCount, label: "Primitives")
                summaryDivider
                summaryMetric(value: viewModel.enabledCount, label: "Workers")
                summaryDivider
                summaryMetric(value: viewModel.unhealthyWorkerCount, label: "Unhealthy")
            }

            if !viewModel.activeEngineHooks.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(.tronPurple)
                    Text(engineHookSummary)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                }
            }

        }
        .padding(14)
        .sectionFill(consoleStatus.color, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var primitiveContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !viewModel.nativeCapabilities.isEmpty {
                WorkerConsoleGroup(
                    title: "Native capabilities",
                    detail: "Fixed authenticated client features. These are not model-callable primitives."
                ) {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.nativeCapabilities, id: \.self) { capability in
                            HStack(spacing: 11) {
                                Image(systemName: capability == "terminal.v1" ? "terminal" : "app.connected.to.app.below.fill")
                                    .foregroundStyle(.tronCyan)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(capability == "terminal.v1" ? "Terminal Mode" : capability)
                                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                    Text("Available to authenticated native clients")
                                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .medium))
                                        .foregroundStyle(.tronTextMuted)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .sectionFill(.tronCyan, cornerRadius: 10, subtle: true, interactive: false)
                        }
                    }
                }
            }
            ForEach(viewModel.primitiveToolGroups) { group in
                EnginePrimitiveSection(group: group.id, tools: group.tools) { tool in
                    selectedPrimitiveTool = tool
                }
            }
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkerConsoleGroup(
                title: "Worker runs",
                detail: "Queued, active, completed, failed, and interrupted invocations."
            ) {
                if viewModel.activityRuns.isEmpty {
                    WorkerConsoleInlineEmptyState(
                        symbol: "waveform.path",
                        text: "No worker runs recorded."
                    )
                } else {
                    LazyVStack(spacing: 9) {
                        ForEach(viewModel.activityRuns) { run in
                            WorkerRunCard(
                                run: run,
                                workerName: viewModel.workerName(for: run.workerId),
                                callerWorkerName: viewModel.callerWorkerName(for: run),
                                onOpen: { selectedRun = run }
                            )
                        }
                    }
                    if viewModel.activityRunsNextOffset != nil {
                        activityLoadMoreButton("Load older runs") {
                            await viewModel.loadOlderActivityRuns(repository: repository)
                        }
                    }
                }
            }

        }
    }

    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.activityResults.isEmpty {
                WorkerConsoleGroup(
                    title: "Durable results",
                    detail: "Available outcomes, results used by an agent, unresolved failures, and verified recoveries."
                ) {
                    WorkerConsoleInlineEmptyState(
                        symbol: "tray",
                        text: "No durable results have been retained."
                    )
                }
            } else {
                resultSection(
                    .needsAttention,
                    title: "Needs attention",
                    detail: "Unresolved failures that still merit investigation or correction."
                )
                resultSection(
                    .available,
                    title: "Available",
                    detail: "Durable outcomes that have not entered an agent's context."
                )
                resultSection(
                    .usedByAgent,
                    title: "Used by agent",
                    detail: "Results already attached to an agent context for follow-up."
                )
                resultSection(
                    .resolved,
                    title: "Resolved",
                    detail: "Earlier failures the server no longer classifies as actionable after recovery or an owned fallback."
                )
                resultSection(
                    .dismissed,
                    title: "Dismissed",
                    detail: "Failures an operator reviewed and dismissed. Their execution evidence remains available."
                )
                if viewModel.activityResultsNextOffset != nil {
                    resultsLoadMoreButton("Load older results") {
                        await viewModel.loadOlderActivityResults(repository: repository)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resultSection(
        _ disposition: WorkerResultDisposition,
        title: String,
        detail: String
    ) -> some View {
        let items = viewModel.activityResults.filter {
            WorkerConsolePresentation.resultDisposition($0) == disposition
        }
        if !items.isEmpty {
            WorkerConsoleGroup(title: title, detail: detail) {
                LazyVStack(spacing: 9) {
                    ForEach(items) { item in
                        WorkerInboxCard(
                            item: item,
                            workerName: viewModel.workerName(for: item.workerId),
                            onOpen: {
                                selectedInboxItem = WorkerInboxSelection(
                                    item: item,
                                    workerName: viewModel.workerName(for: item.workerId)
                                )
                            }
                        )
                    }
                }
            }
        }
    }

    private func activityLoadMoreButton(
        _ title: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 7) {
                if viewModel.isLoadingMoreActivity {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                }
                Text(title)
            }
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(.tronEmerald)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .sectionFill(.tronEmerald, cornerRadius: 10, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoadingMoreActivity)
    }

    private func resultsLoadMoreButton(
        _ title: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 7) {
                if viewModel.isLoadingMoreResults {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                }
                Text(title)
            }
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(.tronEmerald)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .sectionFill(.tronEmerald, cornerRadius: 10, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoadingMoreResults)
    }

    private func scheduledLoadMoreButton(
        _ title: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 7) {
                if viewModel.isLoadingMoreScheduled {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "calendar.badge.plus")
                }
                Text(title)
            }
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(.tronEmerald)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .sectionFill(.tronEmerald, cornerRadius: 10, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoadingMoreScheduled)
    }

    @ViewBuilder
    private var workersContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkerConsoleGroup(
                title: "General workers",
                detail: "Direct chat tools can be called from an ordinary session. Delegated workers run only through another worker, trigger, engine, or client integration."
            ) {
                if !connectionState.isConnected, viewModel.workers.isEmpty {
                    WorkerConsoleEmptyState(
                        symbol: "network.slash",
                        title: "Worker state is offline",
                        detail: "Reconnect to the paired server to inspect and operate persistent workers."
                    )
                } else if !viewModel.hasLoaded && viewModel.isRefreshing {
                    WorkerConsoleLoadingState(title: "Loading workers")
                } else if viewModel.workers.isEmpty {
                    WorkerConsoleEmptyState(
                        symbol: "bolt.badge.clock",
                        title: "No workers yet",
                        detail: "Ask Tron to create a persistent worker. It will appear here once the server activates it."
                    )
                } else if viewModel.activeWorkers.isEmpty {
                    WorkerConsoleInlineEmptyState(
                        symbol: "bolt.slash",
                        text: "No active workers. Restore a retired worker or create one through chat."
                    )
                } else if viewModel.generalWorkers.isEmpty {
                    WorkerConsoleInlineEmptyState(
                        symbol: "bolt.horizontal.circle",
                        text: "No general workers. Integrated workers are listed separately below."
                    )
                } else {
                    workerRows(viewModel.generalWorkers)
                }
            }

            if !viewModel.integratedWorkers.isEmpty {
                WorkerConsoleGroup(
                    title: "Integrated workers",
                    detail: "Workers with declared engine hooks or native client boundaries. Changes require compatibility review."
                ) {
                    workerRows(viewModel.integratedWorkers)
                }
            }

            if !viewModel.retiredWorkers.isEmpty {
                WorkerConsoleGroup(
                    title: "Retired workers",
                    detail: "Inactive workers retained for audit, version history, and restoration."
                ) {
                    workerRows(viewModel.retiredWorkers)
                }
            }
        }
    }

    private func workerRows(_ workers: [WorkerSummaryDTO]) -> some View {
        LazyVStack(spacing: 10) {
            ForEach(workers) { worker in
                let surface = viewModel.availableWorkerTools.first {
                    $0.workerId == worker.workerId
                }
                let architecture = viewModel.architecture(for: worker.workerId)
                Button {
                    Task { await viewModel.select(worker.workerId, repository: repository) }
                } label: {
                    WorkerConsoleRow(
                        worker: worker,
                        surface: surface,
                        architecture: architecture
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var selectedWorkerPresented: Binding<Bool> {
        Binding(
            get: { viewModel.selectedWorkerId != nil },
            set: { if !$0 { viewModel.selectedWorkerId = nil } }
        )
    }

    private var isPresentingChildSheet: Bool {
        viewModel.selectedWorkerId != nil
            || selectedPrimitiveTool != nil
            || selectedRun != nil
            || selectedInboxItem != nil
    }

    private var consoleStatus: (title: String, detail: String, symbol: String, color: Color) {
        if !connectionState.isConnected {
            return ("Engine unavailable", connectionState.displayText, "network.slash", .tronTextMuted)
        }
        if viewModel.stopAll {
            return ("Dispatch paused", "Queued work is durable and ready to resume.", "pause.circle", .tronWarning)
        }
        if viewModel.unhealthyWorkerCount > 0 {
            return ("Needs review", "A worker reported non-healthy server state.", "exclamationmark.triangle", .tronWarning)
        }
        if viewModel.workers.isEmpty {
            return ("Primitives ready", "The fixed engine is active; create workers conversationally with Tron.", "bolt.horizontal.circle", .tronEmerald)
        }
        return ("Engine ready", "Fixed primitives and the persistent worker runtime are active.", "checkmark.seal", .tronEmerald)
    }

    private var engineHookSummary: String {
        let labels = viewModel.activeEngineHooks.map {
            WorkerConsolePresentation.displayLabel($0.hook)
        }
        return "Worker-owned engine policy: \(labels.joined(separator: ", "))"
    }

    private func summaryMetric(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(Color.tronBorder.opacity(0.7))
            .frame(width: 1, height: 31)
    }

    private func refresh() async {
        switch selectedSection {
        case .pastWork:
            await viewModel.refresh(
                repository: repository,
                connectionState: dependencies.connectionRepository.connectionState
            )
        case .results:
            await viewModel.refreshResults(
                repository: repository,
                connectionState: dependencies.connectionRepository.connectionState
            )
        case .scheduled:
            await viewModel.refreshScheduled(
                repository: repository,
                connectionState: dependencies.connectionRepository.connectionState
            )
        case .workers, .primitives:
            await viewModel.refreshSummary(
                repository: repository,
                connectionState: dependencies.connectionRepository.connectionState
            )
        }
    }

    private func ensureLoaded() async {
        let connectionState = dependencies.connectionRepository.connectionState
        switch selectedSection {
        case .pastWork:
            await viewModel.ensureActivityLoaded(
                repository: repository,
                connectionState: connectionState
            )
        case .scheduled:
            await viewModel.ensureScheduledLoaded(
                repository: repository,
                connectionState: connectionState
            )
        case .results:
            await viewModel.ensureResultsLoaded(
                repository: repository,
                connectionState: connectionState
            )
        case .workers, .primitives:
            await viewModel.ensureSummaryLoaded(
                repository: repository,
                connectionState: connectionState
            )
        }
    }

}

private struct ScheduledWorkerCard: View {
    let item: WorkerScheduledWorkItemDTO
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.kind == "recurring" ? "repeat" : "clock")
                    .foregroundStyle(.tronInfo)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.workerName)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(scheduleDetail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                    if let scheduledAt = WorkerConsolePresentation.timestamp(item.scheduledAt) {
                        Text(scheduledAt)
                            .font(TronTypography.sans(size: TronTypography.sizeSM))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                Spacer(minLength: 8)
                Text(item.kind == "recurring" ? "Recurring" : "Scheduled")
                    .font(TronTypography.pillValue)
                    .foregroundStyle(.tronInfo)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .sectionFill(.tronInfo, cornerRadius: 10, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
    }

    private var scheduleDetail: String {
        if item.kind == "recurring", let everySeconds = item.everySeconds {
            return "Repeats \(Self.intervalLabel(everySeconds))"
        }
        return WorkerConsolePresentation.displayLabel(item.triggerKind)
    }

    private static func intervalLabel(_ seconds: UInt64) -> String {
        if seconds.isMultiple(of: 86_400) {
            let days = seconds / 86_400
            return "every \(days) day\(days == 1 ? "" : "s")"
        }
        if seconds.isMultiple(of: 3_600) {
            let hours = seconds / 3_600
            return "every \(hours) hour\(hours == 1 ? "" : "s")"
        }
        if seconds.isMultiple(of: 60) {
            let minutes = seconds / 60
            return "every \(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "every \(seconds) second\(seconds == 1 ? "" : "s")"
    }
}
