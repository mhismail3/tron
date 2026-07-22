import SwiftUI

private enum DelegationSection: String, CaseIterable {
    case tasks = "Tasks"
    case newTask = "New"
    case activity = "Activity"
}

struct DelegationSheet: View {
    @Environment(\.dependencies) private var dependencies

    @Bindable var consoleViewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository
    let connectionState: ConnectionState
    let onOpenSession: (String) -> Void

    @State private var viewModel = DelegationViewModel()
    @State private var selectedSection = DelegationSection.tasks
    @State private var selectedRun: WorkerInvocationDTO?
    @State private var showTechnicalDetails = false
    @State private var technicalViewModel = WorkerConsoleViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard
                    TronSegmentedControl(
                        options: DelegationSection.allCases.map { ($0.rawValue, $0) },
                        selection: $selectedSection,
                        accent: .tronPurple
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
                    SheetTitle(title: "Delegation", color: .tronPurple)
                }
                ToolbarItem(placement: .topBarLeading) {
                    SheetPrimaryActionButton(
                        icon: "arrow.clockwise",
                        accent: .tronPurple,
                        isBusy: viewModel.isLoading,
                        accessibilityLabel: "Refresh delegated tasks"
                    ) {
                        Task { await refresh() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronPurple)
                }
            }
            .sheet(item: $selectedRun) { run in
                DelegationRunDetailSheet(
                    run: run,
                    result: viewModel.resultsByInvocation[run.invocationId],
                    session: cachedSession(for: run),
                    model: cachedSession(for: run)?.latestModel ?? viewModel.runnerModel,
                    isMutating: viewModel.isMutating,
                    onCancel: {
                        Task {
                            await viewModel.cancel(
                                run,
                                repository: repository,
                                connectionState: connectionState,
                                availableWorkers: consoleViewModel.workers
                            )
                            selectedRun = viewModel.runs.first { $0.invocationId == run.invocationId }
                        }
                    },
                    onRetry: {
                        Task {
                            await viewModel.retry(
                                run,
                                repository: repository,
                                connectionState: connectionState,
                                availableWorkers: consoleViewModel.workers
                            )
                            selectedRun = nil
                        }
                    },
                    onOpenSession: onOpenSession
                )
            }
            .sheet(isPresented: $showTechnicalDetails) {
                WorkerDetailSheet(
                    viewModel: technicalViewModel,
                    repository: repository,
                    connectionState: connectionState,
                    mode: .technical
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
        .tint(.tronPurple)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: viewModel.issueCount > 0 ? "person.crop.circle.badge.exclamationmark" : "person.2.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(viewModel.issueCount > 0 ? .tronWarning : .tronPurple)
                    .frame(width: 25)
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.issueCount > 0 ? "Delegation needs review" : "Delegate ready")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("One bounded task per durable child session, with typed results and precise cancellation.")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                metric(viewModel.activeRunCount, "Active")
                divider
                metric(viewModel.completedRunCount, "Completed")
                divider
                metric(viewModel.issueCount, "Issues")
            }
        }
        .padding(14)
        .sectionFill(
            viewModel.issueCount > 0 ? .tronWarning : .tronPurple,
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
                title: "Delegation is offline",
                detail: "Reconnect to inspect, start, cancel, or retry delegated tasks."
            )
        } else if !viewModel.hasLoaded && viewModel.isLoading {
            WorkerConsoleLoadingState(title: "Loading delegated work")
        } else if viewModel.worker == nil {
            WorkerConsoleEmptyState(
                symbol: "person.2.slash",
                title: "General Delegate unavailable",
                detail: "No supported primary Delegation worker is active on this server."
            )
        } else {
            switch selectedSection {
            case .tasks: tasksContent
            case .newTask: newTaskContent
            case .activity: activityContent
            }
        }
    }

    private var tasksContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkerConsoleSectionHeader(
                title: "Delegated tasks",
                detail: "Server-owned status, child-session linkage, result previews, and timing."
            )
            if viewModel.runs.isEmpty {
                WorkerConsoleEmptyState(
                    symbol: "person.crop.circle.badge.plus",
                    title: "No delegated tasks yet",
                    detail: "Create one bounded task. It will run independently and remain inspectable here."
                )
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.runs) { run in
                        Button { selectedRun = run } label: {
                            DelegationRunRow(
                                run: run,
                                result: viewModel.resultsByInvocation[run.invocationId],
                                session: cachedSession(for: run)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            WorkerConsoleSectionHeader(
                title: "Worker contract",
                detail: "The active model and immutable worker version used for newly admitted work."
            )
            Button { Task { await openTechnicalDetails() } } label: {
                HStack(spacing: 11) {
                    Image(systemName: "cpu")
                        .foregroundStyle(.tronPurple)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(viewModel.runnerModel.map(WorkerConsolePresentation.displayLabel) ?? "Agent runner")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                        if let worker = viewModel.worker {
                            Text("v\(WorkerConsolePresentation.compactIdentifier(worker.activeVersion, length: 10)) · technical details")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextMuted)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tronTextMuted)
                }
                .padding(12)
                .sectionFill(.tronPurple, cornerRadius: 11, subtle: true, interactive: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var newTaskContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkerConsoleSectionHeader(
                title: "Delegate one task",
                detail: "Task and deliverable are required. Everything else narrows execution without adding orchestration ceremony."
            )
            DelegationFormTextArea(
                title: "Task",
                detail: "Describe the bounded work to complete.",
                text: $viewModel.task,
                minHeight: 100
            )
            DelegationFormTextArea(
                title: "Deliverable",
                detail: "State exactly what a useful result must contain.",
                text: $viewModel.deliverableDescription,
                minHeight: 78
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Effort")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                TronSegmentedControl(
                    options: [("Low", "low"), ("Standard", "standard"), ("High", "high")],
                    selection: $viewModel.budget,
                    accent: .tronPurple
                )
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    DelegationFormTextArea(
                        title: "Context",
                        detail: "Relevant background, not hidden instructions.",
                        text: $viewModel.context,
                        minHeight: 78
                    )
                    DelegationFormTextArea(
                        title: "Files",
                        detail: "One local path per line. The delegate must inspect each before relying on it.",
                        text: $viewModel.filePaths,
                        minHeight: 74,
                        code: true
                    )
                    DelegationFormTextArea(
                        title: "Constraints",
                        detail: "One explicit constraint per line; every item must be accounted for in the result.",
                        text: $viewModel.constraints,
                        minHeight: 86
                    )
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Deadline")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                        TextField("Optional ISO or human-readable deadline", text: $viewModel.deadline)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .padding(11)
                            .sectionFill(.tronSlate, cornerRadius: 10, subtle: true, interactive: false)
                    }
                    DelegationFormTextArea(
                        title: "Deliverable JSON Schema",
                        detail: "Optional fail-closed schema object for the deliverable value.",
                        text: $viewModel.deliverableSchema,
                        minHeight: 120,
                        code: true
                    )
                }
                .padding(.top, 12)
            } label: {
                Label("Optional guidance", systemImage: "slider.horizontal.3")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronPurple)
            }

            Button {
                Task {
                    if await viewModel.submit(
                        repository: repository,
                        connectionState: connectionState,
                        availableWorkers: consoleViewModel.workers
                    ) {
                        selectedSection = .tasks
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isMutating { ProgressView().controlSize(.small) }
                    Label("Delegate task", systemImage: "paperplane.fill")
                }
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.tronPurple, in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSubmit)
            .opacity(viewModel.canSubmit ? 1 : 0.45)
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkerConsoleSectionHeader(
                title: "Durable results",
                detail: "Notable completions, cancellations, and failures retained by the worker inbox."
            )
            if viewModel.inbox.isEmpty {
                WorkerConsoleInlineEmptyState(symbol: "tray", text: "No Delegation inbox results.")
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(viewModel.inbox) { WorkerInboxCard(item: $0) }
                }
            }

        }
    }

    private func metric(_ value: Int, _ label: String) -> some View {
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

    private var divider: some View {
        Rectangle().fill(Color.tronBorder.opacity(0.7)).frame(width: 1, height: 31)
    }

    private func cachedSession(for run: WorkerInvocationDTO) -> CachedSession? {
        guard let sessionId = run.agentSessionId else { return nil }
        return dependencies.eventStoreManager.sessions.first { $0.id == sessionId }
    }

    private func refresh() async {
        dependencies.eventStoreManager.requestSessionRefresh(reason: .serverHint)
        await viewModel.refresh(
            availableWorkers: consoleViewModel.workers,
            repository: repository,
            connectionState: connectionState
        )
    }

    private func openTechnicalDetails() async {
        guard let worker = viewModel.worker else { return }
        await technicalViewModel.refresh(
            repository: repository,
            connectionState: connectionState
        )
        await technicalViewModel.select(worker.workerId, repository: repository)
        guard technicalViewModel.selectedWorkerId == worker.workerId else { return }
        showTechnicalDetails = true
    }
}

private struct DelegationFormTextArea: View {
    let title: String
    let detail: String
    @Binding var text: String
    let minHeight: CGFloat
    var code = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
            Text(detail)
                .font(TronTypography.sans(size: TronTypography.sizeSM))
                .foregroundStyle(.tronTextSecondary)
            TextEditor(text: $text)
                .font(code
                    ? TronTypography.code(size: TronTypography.sizeBodySM)
                    : TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextPrimary)
                .scrollContentBackground(.hidden)
                .textInputAutocapitalization(code ? .never : .sentences)
                .autocorrectionDisabled(code)
                .frame(minHeight: minHeight)
                .padding(9)
                .sectionFill(.tronSlate, cornerRadius: 10, subtle: true, interactive: false)
        }
    }
}

private struct DelegationRunRow: View {
    let run: WorkerInvocationDTO
    let result: DelegationResult?
    let session: CachedSession?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: statusSymbol)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(DelegationContract.task(from: run))
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(WorkerConsolePresentation.displayLabel(run.status))
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                if let summary = result?.summary {
                    Text(summary)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(3)
                } else if let description = DelegationContract.deliverableDescription(from: run) {
                    Text(description)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text("Attempt \(run.attemptCount)")
                    if let timestamp = WorkerConsolePresentation.timestamp(run.createdAt) { Text(timestamp) }
                    if let session { Text(TokenFormatter.format(session.totalTokens)) }
                }
                .font(TronTypography.sans(size: TronTypography.sizeSM))
                .foregroundStyle(.tronTextMuted)
                if let error = run.error, !error.isEmpty {
                    Text(error)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronError)
                        .lineLimit(3)
                }
            }
            Image(systemName: "chevron.right")
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 3)
        }
        .padding(12)
        .sectionFill(statusColor, cornerRadius: 11, subtle: true, interactive: true)
    }

    private var statusColor: Color { delegationStatusColor(run.status) }
    private var statusSymbol: String {
        switch WorkerConsolePresentation.normalized(run.status) {
        case "completed": "checkmark.circle.fill"
        case "queued": "clock.fill"
        case "running": "person.wave.2.fill"
        case "cancelled": "stop.circle.fill"
        default: "exclamationmark.triangle.fill"
        }
    }
}

func delegationStatusColor(_ status: String) -> Color {
    switch WorkerConsolePresentation.normalized(status) {
    case "completed": .tronSuccess
    case "queued", "running": .tronInfo
    case "cancelled", "partial", "blocked": .tronWarning
    default: .tronError
    }
}
