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
    case overview = "Overview"
    case core = "Core"
    case workers = "Workers"
    case activity = "Activity"
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
                        metric("Visible", viewModel.projectedWorkerCount)
                        metric("Issues", viewModel.attentionCount)
                    }
                }

                Spacer(minLength: 8)

                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(summaryColor)
                } else {
                    Image(systemName: "chevron.right")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
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
        viewModel.attentionCount > 0 ? "exclamationmark.triangle" : "bolt.horizontal.circle"
    }

    private var summaryColor: Color {
        viewModel.attentionCount > 0 ? .tronWarning : .tronEmerald
    }

    private var summaryDetail: String {
        if viewModel.stopAll { return "Dispatch is paused; durable work remains queued." }
        if viewModel.workers.isEmpty { return "Core ready; create persistent workers conversationally." }
        if viewModel.attentionCount > 0 {
            return "\(viewModel.attentionCount) worker\(viewModel.attentionCount == 1 ? " needs" : "s need") review."
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
    @Bindable var viewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository
    let connectionState: ConnectionState
    let sessionId: String?

    @State private var confirmStopAll = false
    @State private var selectedSection: EngineDashboardSection = .overview
    @State private var selectedCoreTool: EngineSurfaceToolDTO?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard
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
                WorkerDetailSheet(
                    viewModel: viewModel,
                    repository: repository,
                    connectionState: connectionState
                )
            }
            .sheet(item: $selectedCoreTool) { tool in
                EngineCoreToolDetailSheet(tool: tool)
            }
            .confirmationDialog(
                "Stop every worker?",
                isPresented: $confirmStopAll,
                titleVisibility: .visible
            ) {
                Button("Stop all workers", role: .destructive) {
                    Task { await setStopped(true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("New dispatch will pause, active work will be cancelled, and resident services will stop. Durable queued work stays visible.")
            }
            .task { await refresh() }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
    }

    @ViewBuilder
    private var dashboardContent: some View {
        switch selectedSection {
        case .overview:
            overviewContent
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
                summaryMetric(value: viewModel.projectedWorkerCount, label: "Visible")
                summaryDivider
                summaryMetric(value: viewModel.availableWorkerCount, label: "Available")
            }

            Button {
                if viewModel.stopAll {
                    Task { await setStopped(false) }
                } else {
                    confirmStopAll = true
                }
            } label: {
                Label(
                    viewModel.stopAll ? "Resume queued work" : "Stop all workers",
                    systemImage: viewModel.stopAll ? "play.fill" : "stop.fill"
                )
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(viewModel.stopAll ? .tronEmerald : .tronError)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .contentShape(Capsule())
                .glassEffect(
                    .regular.tint((viewModel.stopAll ? Color.tronEmerald : .tronError).opacity(0.16)).interactive(),
                    in: .capsule
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isMutating || !connectionState.isConnected)
        }
        .padding(14)
        .sectionFill(consoleStatus.color, cornerRadius: 12, subtle: true, interactive: false)
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkerConsoleSectionHeader(
                title: "Current agent surface",
                detail: "Executable tools resolved for the selected session at the next provider boundary."
            )
            EngineSurfaceCard(viewModel: viewModel)

            if let issue = viewModel.activityInbox.first(where: {
                ["error", "critical", "warning"].contains(
                    WorkerConsolePresentation.normalized($0.severity)
                )
            }) {
                WorkerConsoleSectionHeader(
                    title: "Needs attention",
                    detail: "Most recent durable worker issue."
                )
                WorkerInboxCard(item: issue)
            }
        }
    }

    private var coreContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(["host", "worker_control", "core_change"], id: \.self) { group in
                let tools = viewModel.coreTools.filter { $0.primitiveGroup == group }
                EngineCoreSection(group: group, tools: tools) { tool in
                    selectedCoreTool = tool
                }
            }
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkerConsoleSectionHeader(
                title: "Durable inbox",
                detail: "Results and failures emitted by all persistent workers."
            )
            if viewModel.activityInbox.isEmpty {
                WorkerConsoleInlineEmptyState(
                    symbol: "tray",
                    text: "No durable worker results."
                )
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(viewModel.activityInbox) { WorkerInboxCard(item: $0) }
                }
            }

            WorkerConsoleSectionHeader(
                title: "Worker runs",
                detail: "Queued, active, completed, failed, and interrupted invocations."
            )
            if viewModel.activityRuns.isEmpty {
                WorkerConsoleInlineEmptyState(
                    symbol: "waveform.path",
                    text: "No worker runs recorded."
                )
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(viewModel.activityRuns) { WorkerRunCard(run: $0) }
                }
            }
        }
    }

    @ViewBuilder
    private var workersContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkerConsoleSectionHeader(
                title: "Persistent workers",
                detail: "Each enabled worker is published as its own direct typed tool."
            )

            if !connectionState.isConnected {
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
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.workers) { worker in
                        let surface = viewModel.availableWorkerTools.first {
                            $0.workerId == worker.workerId
                        }
                        Button {
                            Task { await viewModel.select(worker.workerId, repository: repository) }
                        } label: {
                            WorkerConsoleRow(worker: worker, surface: surface)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var selectedWorkerPresented: Binding<Bool> {
        Binding(
            get: { viewModel.selectedWorkerId != nil },
            set: { if !$0 { viewModel.selectedWorkerId = nil } }
        )
    }

    private var consoleStatus: (title: String, detail: String, symbol: String, color: Color) {
        if !connectionState.isConnected {
            return ("Engine unavailable", connectionState.displayText, "network.slash", .tronTextMuted)
        }
        if viewModel.stopAll {
            return ("Dispatch paused", "Queued work is durable and ready to resume.", "pause.circle", .tronWarning)
        }
        if viewModel.attentionCount > 0 {
            return ("Needs review", "A worker reported non-healthy server state.", "exclamationmark.triangle", .tronWarning)
        }
        if viewModel.workers.isEmpty {
            return ("Core ready", "The fixed engine is active; create workers conversationally with Tron.", "bolt.horizontal.circle", .tronEmerald)
        }
        return ("Engine ready", "Core primitives and the persistent worker runtime are active.", "checkmark.seal", .tronEmerald)
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
        await viewModel.refresh(
            repository: repository,
            connectionState: connectionState,
            sessionId: sessionId
        )
    }

    private func setStopped(_ stopped: Bool) async {
        await viewModel.setStopAll(
            stopped,
            repository: repository,
            connectionState: connectionState
        )
    }
}

private struct WorkerConsoleRow: View {
    let worker: WorkerSummaryDTO
    let surface: AvailableWorkerToolDTO?

    private var status: WorkerConsoleStatus {
        WorkerConsolePresentation.status(for: worker)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: status.systemImage)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(status.color)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(worker.name)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)
                    Text(status.title)
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(status.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .glassEffect(.regular.tint(status.color.opacity(0.15)), in: .capsule)
                }

                Text(worker.description)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label(WorkerConsolePresentation.displayLabel(worker.runnerKind), systemImage: "cpu")
                    Label(
                        WorkerConsolePresentation.compactIdentifier(worker.activeVersion, length: 8),
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                    if worker.triggerCount > 0 {
                        Label("\(worker.triggerCount)", systemImage: "alarm")
                    }
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)

                if let surface {
                    HStack(spacing: 6) {
                        workerSurfaceBadge("Published", color: .tronSuccess)
                        if surface.projected {
                            workerSurfaceBadge("This session", color: .tronEmerald)
                        }
                        if surface.promoted {
                            workerSurfaceBadge("Promoted", color: .tronPurple)
                        }
                    }
                    .lineLimit(1)

                    Text("\(surface.modelName) · r\(surface.functionRevision) · \(EngineDashboardPresentation.routingEvidence(surface))")
                        .font(TronTypography.code(size: TronTypography.sizeSM))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 5)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(status.color, cornerRadius: 12, subtle: true, interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(worker.name), \(status.title), \(worker.runnerKind) worker")
    }

    private func workerSurfaceBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .glassEffect(.regular.tint(color.opacity(0.14)), in: .capsule)
    }
}
