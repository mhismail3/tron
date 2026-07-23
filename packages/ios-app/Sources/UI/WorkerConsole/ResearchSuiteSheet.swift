import SwiftUI

private enum ResearchSuiteSection: String, CaseIterable {
    case overview = "Overview"
    case reports = "Reports"
    case activity = "Activity"
}

struct ResearchSuiteSheet: View {
    @Bindable var consoleViewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository
    let connectionState: ConnectionState

    @State private var viewModel = ResearchSuiteViewModel()
    @State private var selectedSection = ResearchSuiteSection.overview
    @State private var selectedReport: ResearchReport?
    @State private var selectedTechnicalWorker: WorkerSummaryDTO?
    @State private var showReportHistoryWarnings = false
    @State private var technicalViewModel = WorkerConsoleViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard
                    TronSegmentedControl(
                        options: ResearchSuiteSection.allCases.map { ($0.rawValue, $0) },
                        selection: $selectedSection,
                        accent: .tronCyan
                    )

                    if let error = viewModel.lastError {
                        WorkerConsoleErrorBanner(message: error)
                    }

                    content
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Research", color: .tronCyan)
                }
                ToolbarItem(placement: .topBarLeading) {
                    SheetPrimaryActionButton(
                        icon: "arrow.clockwise",
                        accent: .tronCyan,
                        isBusy: viewModel.isLoading,
                        accessibilityLabel: "Refresh Research suite"
                    ) {
                        Task { await refresh() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronCyan)
                }
            }
            .sheet(item: $selectedReport) { report in
                ResearchReportSheet(report: report)
            }
            .sheet(item: $selectedTechnicalWorker) { _ in
                WorkerDetailSheet(
                    viewModel: technicalViewModel,
                    repository: repository,
                    connectionState: connectionState,
                    mode: .technical
                )
            }
            .sheet(isPresented: $showReportHistoryWarnings) {
                WorkerTextDetailSheet(
                    title: "Unavailable Report History",
                    values: viewModel.reportHistoryWarnings,
                    accent: .tronInfo
                )
            }
            .task { await refresh() }
            .onChange(of: consoleViewModel.workers) { _, _ in
                Task { await refresh() }
            }
            .onChange(of: consoleViewModel.activityRuns) { _, _ in
                Task { await refresh() }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronCyan)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: viewModel.currentAttentionCount > 0 ? "exclamationmark.magnifyingglass" : "sparkle.magnifyingglass")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(viewModel.currentAttentionCount > 0 ? .tronWarning : .tronCyan)
                    .frame(width: 25)
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.currentAttentionCount > 0 ? "Research needs review" : "Research suite ready")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("Search, source review, citation validation, and durable synthesis in one experience.")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                summaryMetric(viewModel.healthyComponentCount, "Healthy")
                summaryDivider
                summaryMetric(viewModel.reports.count, "Reports")
                summaryDivider
                summaryMetric(viewModel.currentAttentionCount, "Attention")
            }
        }
        .padding(14)
        .sectionFill(
            viewModel.currentAttentionCount > 0 ? .tronWarning : .tronCyan,
            cornerRadius: 12,
            subtle: true,
            interactive: false
        )
    }

    @ViewBuilder
    private var content: some View {
        if !connectionState.isConnected {
            WorkerConsoleEmptyState(
                symbol: "network.slash",
                title: "Research is offline",
                detail: "Reconnect to the paired server to inspect reports and specialist activity."
            )
        } else if !viewModel.hasLoaded && viewModel.isLoading {
            WorkerConsoleLoadingState(title: "Loading Research suite")
        } else if viewModel.workers.isEmpty {
            WorkerConsoleEmptyState(
                symbol: "magnifyingglass.circle",
                title: "Research suite unavailable",
                detail: "No supported primary Research suite is active on this server."
            )
        } else {
            switch selectedSection {
            case .overview: overviewContent
            case .reports: reportsContent
            case .activity: activityContent
            }
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkerConsoleSectionHeader(
                title: "Specialists",
                detail: "One suite, four independently versioned workers and failure domains."
            )
            LazyVStack(spacing: 10) {
                ForEach(viewModel.workers) { worker in
                    ResearchComponentCard(
                        worker: worker,
                        runs: viewModel.runs.filter { $0.workerId == worker.workerId },
                        openDetails: { Task { await openTechnicalDetails(worker) } }
                    )
                }
            }

            WorkerConsoleSectionHeader(
                title: "Latest report",
                detail: "The newest canonical report returned by the coordinator and retained in durable run history."
            )
            if let report = viewModel.latestReport {
                Button { selectedReport = report } label: {
                    ResearchReportRow(report: report)
                }
                .buttonStyle(.plain)
            } else {
                WorkerConsoleInlineEmptyState(
                    symbol: "doc.text.magnifyingglass",
                    text: "No canonical research report has completed yet."
                )
            }

            if let report = viewModel.latestReport,
               !report.evidenceGaps.isEmpty || !report.contradictions.isEmpty {
                WorkerConsoleSectionHeader(
                    title: "Evidence attention",
                    detail: "Visible limitations from the latest report, not client-inferred quality."
                )
                ResearchAttentionCard(report: report)
            }
        }
    }

    private var reportsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkerConsoleSectionHeader(
                title: "Research history",
                detail: "Canonical reports decoded from completed coordinator outputs."
            )
            if viewModel.reports.isEmpty {
                WorkerConsoleEmptyState(
                    symbol: "doc.text.magnifyingglass",
                    title: "No reports yet",
                    detail: "Ask Tron to research a question. Completed reports will appear here with their sources and evidence gaps."
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.reports) { report in
                        Button { selectedReport = report } label: {
                            ResearchReportRow(report: report)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !viewModel.reportHistoryWarnings.isEmpty {
                Button { showReportHistoryWarnings = true } label: {
                    HStack {
                        Label(
                            "\(viewModel.reportHistoryWarnings.count) retained report\(viewModel.reportHistoryWarnings.count == 1 ? "" : "s") unavailable in this app",
                            systemImage: "doc.badge.ellipsis"
                        )
                        Spacer()
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronInfo)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .sectionFill(.tronInfo, cornerRadius: 11, subtle: true, interactive: true)
            }

            WorkerConsoleSectionHeader(
                title: "Suite runs",
                detail: "Coordinator and specialist invocations, including their exact server status and query when available."
            )
            if viewModel.runs.isEmpty {
                WorkerConsoleInlineEmptyState(symbol: "waveform.path", text: "No Research runs recorded.")
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(viewModel.runs) { run in
                        WorkerRunCard(run: run, workerName: viewModel.workerName(for: run.workerId))
                    }
                }
            }

            WorkerConsoleSectionHeader(
                title: "Attention",
                detail: "Failures, system events, and pending background outcomes from suite components."
            )
            if viewModel.attention.isEmpty {
                WorkerConsoleInlineEmptyState(
                    symbol: "checkmark.circle",
                    text: "Nothing needs attention."
                )
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(viewModel.attention) { item in
                        WorkerInboxCard(
                            item: item,
                            workerName: viewModel.workerName(for: item.workerId)
                        )
                    }
                }
            }
        }
    }

    private func summaryMetric(_ value: Int, _ label: String) -> some View {
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
        Rectangle().fill(Color.tronBorder.opacity(0.7)).frame(width: 1, height: 31)
    }

    private func refresh() async {
        await viewModel.refresh(
            availableWorkers: consoleViewModel.workers,
            repository: repository,
            connectionState: connectionState
        )
    }

    private func openTechnicalDetails(_ worker: WorkerSummaryDTO) async {
        await technicalViewModel.refresh(
            repository: repository,
            connectionState: connectionState
        )
        await technicalViewModel.select(worker.workerId, repository: repository)
        guard technicalViewModel.selectedWorkerId == worker.workerId else { return }
        selectedTechnicalWorker = worker
    }
}

private struct ResearchComponentCard: View {
    let worker: WorkerSummaryDTO
    let runs: [WorkerInvocationDTO]
    let openDetails: () -> Void

    private var status: WorkerConsoleStatus { WorkerConsolePresentation.status(for: worker) }

    var body: some View {
        Button(action: openDetails) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: componentSymbol)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(status.color)
                    .frame(width: 25, height: 25)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(worker.name)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                        Spacer()
                        Text(status.title)
                            .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                            .foregroundStyle(status.color)
                    }
                    Text(componentDetail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Label("v\(WorkerConsolePresentation.compactIdentifier(worker.activeVersion, length: 7))", systemImage: "shippingbox")
                        Label("\(runs.count) runs", systemImage: "waveform.path")
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeSM))
                    .foregroundStyle(.tronTextMuted)
                }
            }
            .padding(12)
            .sectionFill(status.color, cornerRadius: 11, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(worker.name) technical details")
    }

    private var componentSymbol: String {
        switch worker.presentation?.componentRole {
        case "coordinator": "point.3.connected.trianglepath.dotted"
        case "search": "magnifyingglass"
        case "source-review": "doc.text.magnifyingglass"
        case "citation": "quote.opening"
        default: "gearshape.2"
        }
    }

    private var componentDetail: String {
        switch worker.presentation?.componentRole {
        case "coordinator": "Plans, coordinates, synthesizes, and stores the final report."
        case "search": "Finds, ranks, and deduplicates candidate sources."
        case "source-review": "Fetches sources and extracts structured evidence."
        case "citation": "Links claims to evidence and rejects unsupported assertions."
        default: worker.description
        }
    }
}

private struct ResearchReportRow: View {
    let report: ResearchReport

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: report.status == "complete" ? "checkmark.seal" : "doc.badge.ellipsis")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(report.status == "complete" ? .tronSuccess : .tronWarning)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(report.question)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    Text(WorkerConsolePresentation.displayLabel(report.status))
                        .foregroundStyle(report.status == "complete" ? .tronSuccess : .tronWarning)
                    Text("\(report.sources.count) sources")
                    Text("\(report.supportedClaimCount)/\(report.claims.count) supported")
                }
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .medium))
                .foregroundStyle(.tronTextMuted)
                if let timestamp = WorkerConsolePresentation.timestamp(report.generatedAt) {
                    Text(timestamp)
                        .font(TronTypography.sans(size: TronTypography.sizeSM))
                        .foregroundStyle(.tronTextMuted)
                }
            }
            Spacer(minLength: 6)
        }
        .padding(12)
        .sectionFill(.tronCyan, cornerRadius: 11, subtle: true, interactive: true)
    }
}

private struct ResearchAttentionCard: View {
    let report: ResearchReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !report.contradictions.isEmpty {
                Label("\(report.contradictions.count) contradiction\(report.contradictions.count == 1 ? "" : "s")", systemImage: "arrow.left.arrow.right")
                    .foregroundStyle(.tronError)
            }
            if !report.evidenceGaps.isEmpty {
                Label("\(report.evidenceGaps.count) evidence gap\(report.evidenceGaps.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.tronWarning)
                Text(report.evidenceGaps[0])
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(3)
            }
        }
        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(.tronWarning, cornerRadius: 11, subtle: true, interactive: false)
    }
}
