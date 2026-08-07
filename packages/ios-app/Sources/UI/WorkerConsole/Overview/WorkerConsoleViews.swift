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
    case core = "Core"
    case activity = "Activity"
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
                        metric("Core", viewModel.coreToolCount)
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
        if viewModel.workers.isEmpty { return "Core ready; create persistent workers conversationally." }
        if viewModel.unhealthyWorkerCount > 0 {
            return "\(viewModel.unhealthyWorkerCount) worker\(viewModel.unhealthyWorkerCount == 1 ? " needs" : "s need") review."
        }
        return "Core primitives and persistent workers are ready."
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
    let modelRepository: any ModelRepository

    @State private var selectedSection: EngineDashboardSection = .workers
    @State private var selectedCoreTool: EngineSurfaceToolDTO?
    @State private var showInboxAudit = false

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
                            repository: repository,
                            modelRepository: modelRepository
                        )
                    }
                } else {
                    WorkerDetailSheet(
                        viewModel: viewModel,
                        repository: repository,
                        modelRepository: modelRepository
                    )
                }
            }
            .sheet(item: $selectedCoreTool) { tool in
                EngineCoreToolDetailSheet(tool: tool)
            }
            .sheet(isPresented: $showInboxAudit) {
                WorkerInboxAuditSheet(
                    workerId: nil,
                    workerNames: Dictionary(
                        uniqueKeysWithValues: viewModel.workers.map { ($0.workerId, $0.name) }
                    ),
                    repository: repository
                )
            }
            .task(id: EngineDashboardRefreshKey(
                continuity: dependencies.connectionRepository.continuity,
                section: selectedSection,
                isCovered: isPresentingChildSheet
            )) {
                guard !isPresentingChildSheet else { return }
                await refresh()
                if selectedSection == .activity {
                    await viewModel.monitor(
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
        case .core:
            coreContent
        case .workers:
            workersContent
        case .activity:
            activityContent
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
                summaryMetric(value: viewModel.coreToolCount, label: "Core")
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

    private var coreContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(["host", "session", "worker_interaction", "worker_administration"], id: \.self) { group in
                let tools = viewModel.coreTools.filter { $0.primitiveGroup == group }
                EngineCoreSection(group: group, tools: tools) { tool in
                    selectedCoreTool = tool
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
                                callerWorkerName: viewModel.callerWorkerName(for: run)
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

            WorkerConsoleGroup(
                title: "Attention",
                detail: "Failures, system events, and pending background outcomes that merit review."
            ) {
                if viewModel.activityAttention.isEmpty {
                    WorkerConsoleInlineEmptyState(
                        symbol: "checkmark.circle",
                        text: "Nothing needs attention."
                    )
                } else {
                    LazyVStack(spacing: 9) {
                        ForEach(viewModel.activityAttention) { item in
                            WorkerInboxCard(
                                item: item,
                                workerName: viewModel.workerName(for: item.workerId)
                            )
                        }
                    }
                    if viewModel.activityAttentionNextOffset != nil {
                        activityLoadMoreButton("Load older attention records") {
                            await viewModel.loadOlderActivityAttention(repository: repository)
                        }
                    }
                }
            }

            Button { showInboxAudit = true } label: {
                HStack(spacing: 11) {
                    Image(systemName: "tray.full")
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open delivery audit")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        Text("Inspect the complete delivery ledger, including routine run-result copies.")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.tronInfo)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sectionFill(.tronInfo, cornerRadius: 11, subtle: true, interactive: true)
            }
            .buttonStyle(.plain)
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

    @ViewBuilder
    private var workersContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkerConsoleGroup(
                title: "Active workers",
                detail: "Direct chat tools and internal policy specialists share one durable runtime."
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
                } else {
                    workerRows(viewModel.activeWorkers)
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
        viewModel.selectedWorkerId != nil || selectedCoreTool != nil || showInboxAudit
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
            return ("Core ready", "The fixed engine is active; create workers conversationally with Tron.", "bolt.horizontal.circle", .tronEmerald)
        }
        return ("Engine ready", "Core primitives and the persistent worker runtime are active.", "checkmark.seal", .tronEmerald)
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
        } else {
            await viewModel.refreshSummary(
                repository: repository,
                connectionState: dependencies.connectionRepository.connectionState
            )
        }
    }

}
