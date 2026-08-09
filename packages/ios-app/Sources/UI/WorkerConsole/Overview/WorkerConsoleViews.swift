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
private enum EngineDashboardSection: String, CaseIterable {
    case workers = "Workers"
    case primitives = "Primitives"
    case activity = "Activity"
    case results = "Results"
}

private struct EngineDashboardRefreshKey: Equatable {
    let continuity: EngineConnectionContinuity
    let section: EngineDashboardSection
    let isCovered: Bool
}

struct WorkerConsoleDashboardBand: View {
    let viewModel: WorkerConsoleViewModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: SessionListLayout.iconTextSpacing) {
                Image(systemName: summarySymbol)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(summaryColor)
                    .frame(
                        width: SessionListLayout.iconColumnWidth,
                        height: SessionListLayout.iconColumnWidth
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text("Engine")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(summaryDetail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        metric("Primitives", viewModel.primitiveToolCount)
                        metric("Workers", viewModel.enabledCount)
                        metric("Unhealthy", viewModel.unhealthyWorkerCount)
                    }
                }

                Spacer(minLength: 8)

                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(summaryColor)
                }
            }
            .padding(.horizontal, SessionListLayout.rowContentHorizontalPadding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .sectionFill(summaryColor, cornerRadius: 12, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("engine-dashboard-band")
        .accessibilityLabel("Open engine dashboard")
    }

    private var summarySymbol: String {
        viewModel.unhealthyWorkerCount > 0 ? "exclamationmark.triangle" : "bolt.horizontal.circle"
    }

    private var summaryColor: Color {
        viewModel.unhealthyWorkerCount > 0 ? .tronWarning : .tronEmerald
    }

    private var summaryDetail: String {
        if viewModel.stopAll { return "Dispatch is paused; durable work remains queued." }
        if viewModel.workers.isEmpty { return "Primitives ready; create persistent workers conversationally." }
        if viewModel.unhealthyWorkerCount > 0 {
            return "\(viewModel.unhealthyWorkerCount) worker\(viewModel.unhealthyWorkerCount == 1 ? " needs" : "s need") review."
        }
        return "Fixed primitives and persistent workers are ready."
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text("\(value)")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(summaryColor)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .lineLimit(1)
    }
}

struct WorkerConsoleSheet: View {
    @Environment(\.dependencies) private var dependencies
    @Bindable var viewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository

    @State private var selectedSection: EngineDashboardSection = .workers
    @State private var selectedPrimitiveTool: EngineSurfaceToolDTO?
    @State private var selectedRun: WorkerInvocationDTO?
    @State private var selectedInboxItem: WorkerInboxSelection?
    @State private var loadedContinuity: EngineConnectionContinuity?

    private var connectionState: ConnectionState {
        dependencies.connectionRepository.connectionState
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    summaryCard
                    if !connectionState.isConnected, viewModel.hasLoaded {
                        WorkerConsoleContinuityBanner()
                    }
                    TronSegmentedControl(
                        options: EngineDashboardSection.allCases.map { ($0.rawValue, $0) },
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
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Engine", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarLeading) {
                    SheetPrimaryActionButton(
                        icon: "arrow.clockwise",
                        accent: .tronEmerald,
                        isBusy: viewModel.isRefreshing,
                        accessibilityLabel: "Refresh engine state"
                    ) {
                        Task { await refresh() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
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
                WorkerInboxDetailSheet(selection: selection, repository: repository)
            }
            .task(id: EngineDashboardRefreshKey(
                continuity: dependencies.connectionRepository.continuity,
                section: selectedSection,
                isCovered: isPresentingChildSheet
            )) {
                guard !isPresentingChildSheet else { return }
                let continuity = dependencies.connectionRepository.continuity
                let isReconnect = loadedContinuity != nil && loadedContinuity != continuity
                loadedContinuity = continuity
                if isReconnect {
                    await refresh()
                } else {
                    await ensureLoaded()
                }
                if selectedSection == .activity {
                    await viewModel.monitor(
                        repository: repository,
                        connectionState: dependencies.connectionRepository.connectionState
                    )
                } else if selectedSection == .results {
                    await viewModel.monitorResults(
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
        .workerConsoleSheetPresentation()
        .tint(.tronEmerald)
    }

    @ViewBuilder
    private var dashboardContent: some View {
        switch selectedSection {
        case .primitives:
            primitiveContent
        case .workers:
            workersContent
        case .activity:
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

    @ViewBuilder
    private var workersContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkerConsoleGroup(
                title: "Workers",
                detail: "Dynamic direct and delegated workers share one durable runtime."
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
                } else if viewModel.dynamicWorkers.isEmpty {
                    WorkerConsoleInlineEmptyState(
                        symbol: "bolt.horizontal.circle",
                        text: "No dynamic workers. Engine specialists are listed separately below."
                    )
                } else {
                    workerRows(viewModel.dynamicWorkers)
                }
            }

            if !viewModel.engineSpecialistWorkers.isEmpty {
                WorkerConsoleGroup(
                    title: "Engine specialists",
                    detail: "Workers with declared hooks into core engine policy. Changes require compatibility review."
                ) {
                    workerRows(viewModel.engineSpecialistWorkers)
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
        if selectedSection == .activity {
            await viewModel.refresh(
                repository: repository,
                connectionState: dependencies.connectionRepository.connectionState
            )
        } else if selectedSection == .results {
            await viewModel.refreshResults(
                repository: repository,
                connectionState: dependencies.connectionRepository.connectionState
            )
        } else {
            await viewModel.refreshSummary(
                repository: repository,
                connectionState: dependencies.connectionRepository.connectionState
            )
        }
    }

    private func ensureLoaded() async {
        let connectionState = dependencies.connectionRepository.connectionState
        switch selectedSection {
        case .activity:
            await viewModel.ensureActivityLoaded(
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
