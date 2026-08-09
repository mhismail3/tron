import SwiftUI

enum WorkerDetailMode {
    case operational
    case technical
}

private enum WorkerDetailSection: Hashable {
    case overview
    case manage
    case activity
    case results
}

struct WorkerDetailSheet: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository
    var mode: WorkerDetailMode = .operational

    private var connectionState: ConnectionState {
        dependencies.connectionRepository.connectionState
    }

    @State private var confirmRetire = false
    @State private var confirmPurge = false
    @State private var showSchema = false
    @State private var showTechnicalDetails = false
    @State private var showInboxAudit = false
    @State private var selectedRun: WorkerInvocationDTO?
    @State private var selectedInboxItem: WorkerInboxSelection?
    @State private var selectedSection = WorkerDetailSection.overview
    @State private var loadedContinuity: EngineConnectionContinuity?
    @State private var isLifecycleAuditExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if !connectionState.isConnected,
                       viewModel.inspection != nil {
                        WorkerConsoleContinuityBanner()
                    }
                    if viewModel.isLoadingSelection {
                        WorkerConsoleLoadingState(title: "Loading worker")
                    } else if let worker = viewModel.selectedWorker,
                              let inspection = viewModel.inspection {
                        TronSegmentedControl(
                            options: sectionOptions,
                            selection: $selectedSection,
                            accent: .tronEmerald
                        )
                        detailContent(worker, inspection: inspection)
                    } else {
                        WorkerConsoleEmptyState(
                            symbol: "exclamationmark.triangle",
                            title: "Worker details unavailable",
                            detail: viewModel.lastError ?? "Refresh the console and try again."
                        )
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(
                        title: viewModel.selectedWorker?.name ?? "Worker",
                        color: .tronEmerald
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
            .confirmationDialog(
                "Retire this worker?",
                isPresented: $confirmRetire,
                titleVisibility: .visible
            ) {
                Button("Retire worker", role: .destructive) {
                    Task {
                        await viewModel.retire(
                            repository: repository,
                            connectionState: connectionState
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The worker will stop receiving work but its versions and durable history will be retained.")
            }
            .task(id: dependencies.connectionRepository.continuity) {
                guard dependencies.connectionRepository.connectionState.isConnected else { return }
                let continuity = dependencies.connectionRepository.continuity
                let isReconnect = loadedContinuity != nil && loadedContinuity != continuity
                loadedContinuity = continuity
                if isReconnect {
                    await viewModel.reconcileSelection(repository: repository)
                } else {
                    await viewModel.ensureSelectionLoaded(repository: repository)
                }
            }
            .confirmationDialog(
                "Archive and purge this worker?",
                isPresented: $confirmPurge,
                titleVisibility: .visible
            ) {
                Button("Archive and purge", role: .destructive) {
                    Task {
                        await viewModel.purge(
                            repository: repository,
                            connectionState: connectionState
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Tron verifies a local recovery archive, then removes the retired worker and its live state. Restoring the archive is a manual operator action.")
            }
            .sheet(isPresented: $showSchema) {
                if let schema = viewModel.inspection?.bundle["inputSchema"] {
                    WorkerJSONDetailSheet(title: "Input Schema", value: schema, accent: .tronInfo)
                }
            }
            .sheet(isPresented: $showTechnicalDetails) {
                if let worker = viewModel.selectedWorker,
                   let inspection = viewModel.inspection {
                    WorkerTechnicalDetailsSheet(
                        viewModel: viewModel,
                        worker: worker,
                        inspection: inspection
                    )
                }
            }
            .sheet(isPresented: $showInboxAudit) {
                if let worker = viewModel.selectedWorker {
                    WorkerInboxAuditSheet(
                        workerId: worker.workerId,
                        workerNames: [worker.workerId: worker.name],
                        repository: repository
                    )
                }
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
                                connectionState: connectionState
                            )
                            selectedRun = viewModel.runs.first {
                                $0.invocationId == run.invocationId
                            }
                        }
                    } : nil
                )
            }
            .sheet(item: $selectedInboxItem) { selection in
                WorkerInboxDetailSheet(selection: selection, repository: repository)
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronEmerald)
    }

    private var sectionOptions: [(String, WorkerDetailSection)] {
        switch mode {
        case .operational:
            [("Overview", .overview), ("Manage", .manage), ("Activity", .activity), ("Results", .results)]
        case .technical:
            [("Contract", .overview), ("Manage", .manage)]
        }
    }

    @ViewBuilder
    private func detailContent(
        _ worker: WorkerSummaryDTO,
        inspection: WorkerInspectResultDTO
    ) -> some View {
        switch selectedSection {
        case .overview:
            overview(worker)
            inputContract(inspection)
            triggers(inspection)
        case .manage:
            useInChat(worker)
            versions(worker, inspection: inspection)
            lifecycle(worker)
            lifecycleAudit(inspection)
        case .activity:
            recentRuns
        case .results:
            workerResults
            inboxAudit
        }
    }

    private func overview(_ worker: WorkerSummaryDTO) -> some View {
        let status = WorkerConsolePresentation.status(for: worker)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: status.systemImage)
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(status.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title)
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(status.detail)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer()
            }

            Text(worker.description)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Button { showTechnicalDetails = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "info.circle")
                    Text("View details")
                    Spacer(minLength: 0)
                }
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronInfo)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sectionFill(.tronInfo, cornerRadius: 10, subtle: true, interactive: true)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .sectionFill(status.color, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func inputContract(_ inspection: WorkerInspectResultDTO) -> some View {
        let schema = inspection.bundle["inputSchema"]
        let fields = WorkerConsolePresentation.schemaFields(from: schema)

        return WorkerConsoleSection(
            title: "Input contract",
            detail: "The immutable typed input accepted by this worker's direct tool.",
            accent: .tronEmerald
        ) {
            VStack(alignment: .leading, spacing: 13) {
                if fields.isEmpty {
                    WorkerConsoleInlineEmptyState(
                        symbol: "curlybraces",
                        text: "This worker accepts an empty JSON object."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Input fields")
                            .font(
                                TronTypography.sans(
                                    size: TronTypography.sizeCaption,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(.tronTextMuted)
                        ForEach(fields) { field in
                            WorkerSchemaFieldRow(field: field)
                        }
                    }
                }

                if schema != nil {
                    Button { showSchema = true } label: {
                        HStack {
                            Label("Raw input schema", systemImage: "curlybraces.square")
                            Spacer()
                        }
                        .font(
                            TronTypography.sans(
                                size: TronTypography.sizeBodySM,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.tronInfo)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func triggers(_ inspection: WorkerInspectResultDTO) -> some View {
        WorkerConsoleGroup(
            title: "Triggers",
            detail: "Server-owned routes that can dispatch this worker."
        ) {
            if inspection.triggers.isEmpty {
                WorkerConsoleInlineEmptyState(
                    symbol: "hand.tap",
                    text: "Manual invocation only. No automatic triggers are enabled."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(inspection.triggers) { trigger in
                        WorkerTriggerCard(
                            trigger: trigger,
                            isMutating: viewModel.isMutating || !connectionState.isConnected,
                            rotate: trigger.kind == "webhook" ? {
                                Task {
                                    await viewModel.rotateWebhook(
                                        triggerId: trigger.triggerId,
                                        repository: repository,
                                        connectionState: connectionState
                                    )
                                }
                            } : nil
                        )
                    }

                    if let credential = viewModel.webhookCredential {
                        VStack(alignment: .leading, spacing: 7) {
                            Label("New webhook credential", systemImage: "key.fill")
                                .font(
                                    TronTypography.sans(
                                        size: TronTypography.sizeBodySM,
                                        weight: .semibold
                                    )
                                )
                                .foregroundStyle(.tronWarning)
                            Text("Copy this token now. It is shown only from the rotation response.")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextSecondary)
                            WorkerMetadataRow(
                                label: "Path",
                                value: credential.path,
                                isCode: true
                            )
                            WorkerMetadataRow(
                                label: "Token",
                                value: credential.token,
                                isCode: true
                            )
                        }
                        .padding(11)
                        .sectionFill(
                            .tronWarning,
                            cornerRadius: 10,
                            subtle: true,
                            interactive: false
                        )
                        .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func useInChat(_ worker: WorkerSummaryDTO) -> some View {
        return WorkerConsoleSection(
            title: "Use in a new chat",
            detail: "Describe what you want in normal language. The agent will gather genuinely missing details, translate your request into typed input, and invoke this worker.",
            accent: .tronEmerald
        ) {
            VStack(alignment: .leading, spacing: 13) {
                Label("No JSON or schema knowledge required", systemImage: "text.bubble")
                    .font(TronTypography.sans(
                        size: TronTypography.sizeBodySM,
                        weight: .semibold
                    ))
                    .foregroundStyle(.tronTextSecondary)

                TronPrimaryActionButton(
                    title: "Start new chat",
                    systemImage: "bubble.left.and.text.bubble.right.fill",
                    accent: .tronEmerald,
                    isEnabled: connectionState.isConnected
                        && worker.enabled
                        && !worker.retired
                ) {
                    startAgentSessionHandoff(.worker(
                        workerId: worker.workerId,
                        name: worker.name
                    ))
                    dismiss()
                }
            }
        }
    }

    private func versions(
        _ worker: WorkerSummaryDTO,
        inspection: WorkerInspectResultDTO
    ) -> some View {
        WorkerConsoleSection(
            title: "Versions",
            detail: "Immutable retained bundles. Rollback changes canonical active state.",
            accent: .tronPurple
        ) {
            if inspection.versions.isEmpty {
                WorkerConsoleInlineEmptyState(symbol: "clock.arrow.circlepath", text: "No retained versions.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(inspection.versions.enumerated()), id: \.element.id) { index, version in
                        WorkerVersionRow(
                            worker: worker,
                            version: version,
                            isMutating: viewModel.isMutating || !connectionState.isConnected
                        ) {
                            Task {
                                await viewModel.rollback(
                                    to: version.version,
                                    repository: repository,
                                    connectionState: connectionState
                                )
                            }
                        }
                        if index < inspection.versions.count - 1 {
                            WorkerMetadataDivider()
                        }
                    }
                }
            }
        }
    }

    private var recentRuns: some View {
        WorkerConsoleGroup(
            title: "Recent runs",
            detail: "Execution and delivery-attempt history from the durable worker queue."
        ) {
            if viewModel.runs.isEmpty {
                WorkerConsoleInlineEmptyState(symbol: "waveform.path", text: "No runs recorded yet.")
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.runs.prefix(20)) { run in
                        WorkerRunCard(
                            run: run,
                            workerName: viewModel.workerName(for: run.workerId),
                            callerWorkerName: viewModel.callerWorkerName(for: run),
                            onOpen: { selectedRun = run }
                        )
                    }
                }
            }
        }
    }

    private var workerResults: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.selectedResults.isEmpty {
                WorkerConsoleGroup(
                    title: "Durable results",
                    detail: "Outcomes retained independently from execution activity."
                ) {
                    WorkerConsoleInlineEmptyState(
                        symbol: "tray",
                        text: "No durable results have been retained."
                    )
                }
            } else {
                workerResultSection(
                    .needsAttention,
                    title: "Needs attention",
                    detail: "Unresolved failures that still merit investigation or correction."
                )
                workerResultSection(
                    .available,
                    title: "Available",
                    detail: "Outcomes that have not entered an agent context."
                )
                workerResultSection(
                    .usedByAgent,
                    title: "Used by agent",
                    detail: "Results already consumed for agent follow-up."
                )
                workerResultSection(
                    .resolved,
                    title: "Resolved",
                    detail: "Earlier failures followed by verified recovery or an owned fallback."
                )
            }
        }
    }

    @ViewBuilder
    private func workerResultSection(
        _ disposition: WorkerResultDisposition,
        title: String,
        detail: String
    ) -> some View {
        let items = viewModel.selectedResults.filter {
            WorkerConsolePresentation.resultDisposition($0) == disposition
        }
        if !items.isEmpty {
            WorkerConsoleGroup(title: title, detail: detail) {
                VStack(spacing: 10) {
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

    private func lifecycleAudit(_ inspection: WorkerInspectResultDTO) -> some View {
        DisclosureGroup(isExpanded: $isLifecycleAuditExpanded) {
            if inspection.audit.isEmpty {
                WorkerConsoleInlineEmptyState(
                    symbol: "checklist",
                    text: "No lifecycle entries recorded."
                )
                .padding(.top, 10)
            } else {
                VStack(spacing: 10) {
                    ForEach(inspection.audit.prefix(20)) { item in
                        WorkerAuditCard(item: item)
                    }
                }
                .padding(.top, 10)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lifecycle history")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text("Server-authored enable, update, rollback, failure, and retirement evidence.")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }
        }
        .tint(.tronPurple)
        .padding(12)
        .sectionFill(.tronPurple, cornerRadius: 11, subtle: true, interactive: true)
    }

    private var inboxAudit: some View {
        Button { showInboxAudit = true } label: {
            HStack(spacing: 11) {
                Image(systemName: "tray.full")
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open delivery audit")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    Text("Inspect every retained delivery record without duplicating runs here.")
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

    private func lifecycle(_ worker: WorkerSummaryDTO) -> some View {
        WorkerConsoleGroup(
            title: "Lifecycle",
            detail: worker.retired
                ? "Restore a retained version, or permanently remove this retired worker."
                : "Operational controls preserve durable state unless you explicitly retire the worker."
        ) {
            VStack(spacing: 9) {
                if worker.retired {
                    Label("Choose Restore beside any retained version to reactivate this worker.", systemImage: "arrow.uturn.backward.circle")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    WorkerLifecycleButton(
                        title: "Purge permanently",
                        symbol: "trash",
                        color: .tronError,
                        isEnabled: connectionState.isConnected && !viewModel.isMutating,
                        action: { confirmPurge = true }
                    )
                } else {
                    if worker.enabled {
                        WorkerLifecycleButton(
                            title: "Stop current work",
                            symbol: "stop.circle",
                            color: .tronWarning,
                            isEnabled: connectionState.isConnected && !viewModel.isMutating
                        ) {
                            Task {
                                await viewModel.stop(
                                    repository: repository,
                                    connectionState: connectionState
                                )
                            }
                        }
                    }

                    WorkerLifecycleButton(
                        title: worker.enabled ? "Disable new work" : "Enable worker",
                        symbol: worker.enabled ? "pause.circle" : "play.circle",
                        color: worker.enabled ? .tronWarning : .tronEmerald,
                        isEnabled: connectionState.isConnected && !viewModel.isMutating
                    ) {
                        Task {
                            await viewModel.setEnabled(
                                !worker.enabled,
                                repository: repository,
                                connectionState: connectionState
                            )
                        }
                    }

                    Rectangle()
                        .fill(Color.tronBorder.opacity(0.65))
                        .frame(height: 0.5)
                        .padding(.vertical, 2)

                    WorkerLifecycleButton(
                        title: "Retire worker",
                        symbol: "archivebox",
                        color: .tronError,
                        isEnabled: connectionState.isConnected && !viewModel.isMutating,
                        action: { confirmRetire = true }
                    )
                }
            }
        }
    }
}
