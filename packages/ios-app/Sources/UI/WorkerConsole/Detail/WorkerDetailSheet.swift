import SwiftUI

enum WorkerDetailMode {
    case operational
    case technical
}

private enum WorkerDetailSection: Hashable {
    case overview
    case run
    case activity
    case manage
}

struct WorkerDetailSheet: View {
    @Environment(\.dependencies) private var dependencies
    @Bindable var viewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository
    let modelRepository: any ModelRepository
    var mode: WorkerDetailMode = .operational

    private var connectionState: ConnectionState {
        dependencies.connectionRepository.connectionState
    }

    @State private var confirmRetire = false
    @State private var confirmPurge = false
    @State private var showSchema = false
    @State private var showTechnicalDetails = false
    @State private var showInboxAudit = false
    @State private var selectedSection = WorkerDetailSection.overview
    @State private var availableModels: [ModelInfo] = []
    @State private var invocationModel = ""
    @State private var invocationReasoningLevel = ""

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
                do {
                    availableModels = try await modelRepository.list(forceRefresh: true)
                } catch where ConnectionErrorClassifier.isTransientTransport(error) {
                    // Keep the last model projection until the next epoch.
                } catch {
                    availableModels = modelRepository.cachedModels
                }
                await viewModel.reconcileSelection(repository: repository)
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
        }
        .workerConsoleSheetPresentation()
        .tint(.tronEmerald)
    }

    private var sectionOptions: [(String, WorkerDetailSection)] {
        switch mode {
        case .operational:
            [("Overview", .overview), ("Run", .run), ("Activity", .activity), ("Manage", .manage)]
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
        case .run:
            invocation(inspection)
        case .activity:
            recentRuns
            attention
            inboxAudit
            audit(inspection)
        case .manage:
            versions(worker, inspection: inspection)
            lifecycle(worker)
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

    private func invocation(_ inspection: WorkerInspectResultDTO) -> some View {
        let schema = inspection.bundle["inputSchema"]
        let fields = WorkerConsolePresentation.schemaFields(from: schema)
        let selectedModel = availableModels.first { $0.id == invocationModel }
        let reasoningLevels = selectedModel?.reasoningLevels ?? []

        return WorkerConsoleSection(
            title: "New invocation",
            detail: "Run this worker with typed input validated by its immutable schema.",
            accent: .tronEmerald
        ) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    Menu {
                        Button("Worker default") {
                            invocationModel = ""
                            invocationReasoningLevel = ""
                        }
                        ForEach(availableModels.filter { !$0.isDisabled }) { model in
                            Button(model.name) {
                                invocationModel = model.id
                                invocationReasoningLevel = model.defaultReasoningLevel ?? ""
                            }
                        }
                    } label: {
                        WorkerInvocationOptionLabel(
                            title: "Model",
                            value: selectedModel?.name ?? "Worker default",
                            symbol: "cpu"
                        )
                    }

                    if selectedModel?.supportsReasoning == true, !reasoningLevels.isEmpty {
                        Menu {
                            ForEach(reasoningLevels, id: \.self) { level in
                                Button(level.capitalized) {
                                    invocationReasoningLevel = level
                                }
                            }
                        } label: {
                            WorkerInvocationOptionLabel(
                                title: "Reasoning",
                                value: invocationReasoningLevel.isEmpty
                                    ? "Model default"
                                    : invocationReasoningLevel.capitalized,
                                symbol: "brain"
                            )
                        }
                    }
                }

                if fields.isEmpty {
                    WorkerConsoleInlineEmptyState(
                        symbol: "curlybraces",
                        text: "This worker accepts an empty JSON object."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Input fields")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
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
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronInfo)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("JSON input")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                        Spacer()
                        if !viewModel.invocationJSONIsValid {
                            Label("Invalid JSON", systemImage: "exclamationmark.triangle")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                                .foregroundStyle(.tronError)
                        }
                    }

                    TextEditor(text: $viewModel.invocationInput)
                        .font(TronTypography.code(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextPrimary)
                        .scrollContentBackground(.hidden)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 116)
                        .padding(10)
                        .sectionFill(
                            viewModel.invocationJSONIsValid ? .tronSlate : .tronError,
                            cornerRadius: 10,
                            subtle: true,
                            compact: false,
                            interactive: false
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    viewModel.invocationJSONIsValid
                                        ? Color.tronBorder.opacity(0.55)
                                        : Color.tronError.opacity(0.55),
                                    lineWidth: 0.5
                                )
                        }
                }

                TronPrimaryActionButton(
                    title: "Run worker",
                    systemImage: "play.fill",
                    accent: .tronEmerald,
                    isBusy: viewModel.isMutating,
                    isEnabled: connectionState.isConnected
                        && viewModel.canInvokeSelectedWorker
                ) {
                    Task {
                        await viewModel.invoke(
                            repository: repository,
                            connectionState: connectionState,
                            model: invocationModel.isEmpty ? nil : invocationModel,
                            reasoningLevel: invocationReasoningLevel.isEmpty
                                ? nil
                                : invocationReasoningLevel
                        )
                    }
                }

                if let result = viewModel.invocationResult {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Invocation accepted", systemImage: "checkmark.circle.fill")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronSuccess)
                        WorkerCodeBlock(text: result, accent: .tronSuccess)
                    }
                }
            }
        }
    }

    private struct WorkerInvocationOptionLabel: View {
        let title: String
        let value: String
        let symbol: String

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Text(value)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectionFill(.tronEmerald, cornerRadius: 10, subtle: true, interactive: true)
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
                            callerWorkerName: viewModel.callerWorkerName(for: run)
                        ) {
                            Task {
                                await viewModel.cancel(
                                    run,
                                    repository: repository,
                                    connectionState: connectionState
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var attention: some View {
        WorkerConsoleGroup(
            title: "Attention",
            detail: "Failures, system events, and pending background outcomes that merit review."
        ) {
            if viewModel.attention.isEmpty {
                WorkerConsoleInlineEmptyState(
                    symbol: "checkmark.circle",
                    text: "Nothing needs attention."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.attention.prefix(20)) { item in
                        WorkerInboxCard(item: item)
                    }
                }
            }
        }
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

    private func audit(_ inspection: WorkerInspectResultDTO) -> some View {
        WorkerConsoleGroup(
            title: "Audit history",
            detail: "Server-authored lifecycle evidence for this worker."
        ) {
            if inspection.audit.isEmpty {
                WorkerConsoleInlineEmptyState(symbol: "checklist", text: "No audit entries recorded.")
            } else {
                VStack(spacing: 10) {
                    ForEach(inspection.audit.prefix(20)) { item in
                        WorkerAuditCard(item: item)
                    }
                }
            }
        }
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
