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
                    Text("Workers")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(summaryDetail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        metric("Healthy", viewModel.healthyCount)
                        metric("Enabled", viewModel.enabledCount)
                        metric("Total", viewModel.workers.count)
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
        .accessibilityIdentifier("worker-console-dashboard-band")
        .accessibilityLabel("Open worker console")
    }

    private var summarySymbol: String {
        viewModel.attentionCount > 0 ? "exclamationmark.triangle" : "bolt.horizontal.circle"
    }

    private var summaryColor: Color {
        viewModel.attentionCount > 0 ? .tronWarning : .tronEmerald
    }

    private var summaryDetail: String {
        if viewModel.stopAll { return "Dispatch is paused; durable work remains queued." }
        if viewModel.workers.isEmpty { return "Create a persistent worker conversationally." }
        if viewModel.attentionCount > 0 {
            return "\(viewModel.attentionCount) worker\(viewModel.attentionCount == 1 ? " needs" : "s need") review."
        }
        return "Persistent autonomous work is ready."
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

    @State private var confirmStopAll = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard
                    if let error = viewModel.lastError ?? viewModel.monitoringError {
                        WorkerConsoleErrorBanner(message: error)
                    }
                    workersContent
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Worker Console", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarLeading) {
                    SheetPrimaryActionButton(
                        icon: "arrow.clockwise",
                        accent: .tronEmerald,
                        isBusy: viewModel.isRefreshing,
                        accessibilityLabel: "Refresh workers"
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
            .task {
                await viewModel.monitor(repository: repository, connectionState: connectionState)
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
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
                summaryMetric(value: viewModel.healthyCount, label: "Healthy")
                summaryDivider
                summaryMetric(value: viewModel.enabledCount, label: "Enabled")
                summaryDivider
                summaryMetric(value: viewModel.workers.count, label: "Persistent")
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
                        Button {
                            Task { await viewModel.select(worker.workerId, repository: repository) }
                        } label: {
                            WorkerConsoleRow(worker: worker)
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
            return ("Workers unavailable", connectionState.displayText, "network.slash", .tronTextMuted)
        }
        if viewModel.stopAll {
            return ("Dispatch paused", "Queued work is durable and ready to resume.", "pause.circle", .tronWarning)
        }
        if viewModel.attentionCount > 0 {
            return ("Needs review", "A worker reported non-healthy server state.", "exclamationmark.triangle", .tronWarning)
        }
        if viewModel.workers.isEmpty {
            return ("Ready for workers", "Create autonomous workers conversationally with Tron.", "bolt.horizontal.circle", .tronEmerald)
        }
        return ("Workers ready", "The persistent worker runtime is healthy and accepting work.", "checkmark.seal", .tronEmerald)
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
        await viewModel.refresh(repository: repository, connectionState: connectionState)
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
                .lineLimit(1)
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
}

private struct WorkerDetailSheet: View {
    @Bindable var viewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository
    let connectionState: ConnectionState

    @State private var confirmRetire = false
    @State private var confirmPurge = false
    @State private var schemaExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if viewModel.isLoadingSelection {
                        WorkerConsoleLoadingState(title: "Loading worker")
                    } else if let worker = viewModel.selectedWorker,
                              let inspection = viewModel.inspection {
                        overview(worker, inspection: inspection)
                        invocation(worker, inspection: inspection)
                        triggers(inspection)
                        versions(worker, inspection: inspection)
                        recentRuns
                        inbox
                        audit(inspection)
                        lifecycle(worker)
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
            .confirmationDialog(
                "Permanently purge this worker?",
                isPresented: $confirmPurge,
                titleVisibility: .visible
            ) {
                Button("Purge permanently", role: .destructive) {
                    Task {
                        await viewModel.purge(
                            repository: repository,
                            connectionState: connectionState
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the retired worker and its retained state. This cannot be undone.")
            }
        }
        .adaptivePresentationDetents([.large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
    }

    private func overview(_ worker: WorkerSummaryDTO, inspection: WorkerInspectResultDTO) -> some View {
        let status = WorkerConsolePresentation.status(for: worker)
        let provenance = WorkerConsolePresentation.provenance(
            from: inspection.bundle["provenance"]
        )

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

            VStack(spacing: 0) {
                WorkerMetadataRow(label: "Direct tool", value: worker.toolName, isCode: true)
                WorkerMetadataDivider()
                WorkerMetadataRow(
                    label: "Runner",
                    value: WorkerConsolePresentation.displayLabel(worker.runnerKind)
                )
                WorkerMetadataDivider()
                WorkerMetadataRow(
                    label: "Active version",
                    value: WorkerConsolePresentation.compactIdentifier(worker.activeVersion),
                    isCode: true
                )
                if let updated = WorkerConsolePresentation.timestamp(worker.updatedAt) {
                    WorkerMetadataDivider()
                    WorkerMetadataRow(label: "Updated", value: updated)
                }
            }

            if !provenance.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provenance")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                    FlowLayout(spacing: 6) {
                        ForEach(provenance) { item in
                            Text(item.revision.map { "\(item.source) · \($0)" } ?? item.source)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                                .foregroundStyle(.tronInfo)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .glassEffect(.regular.tint(Color.tronInfo.opacity(0.15)), in: .capsule)
                        }
                    }
                }
            }
        }
        .padding(14)
        .sectionFill(status.color, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func invocation(
        _ worker: WorkerSummaryDTO,
        inspection: WorkerInspectResultDTO
    ) -> some View {
        let schema = inspection.bundle["inputSchema"]
        let fields = WorkerConsolePresentation.schemaFields(from: schema)

        return WorkerConsoleSection(
            title: "Typed invocation",
            detail: "Call the provider-facing tool with input validated by this worker's schema.",
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
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                        ForEach(fields) { field in
                            WorkerSchemaFieldRow(field: field)
                        }
                    }
                }

                if let schema {
                    DisclosureGroup(isExpanded: $schemaExpanded) {
                        WorkerJSONBlock(value: schema, accent: .tronInfo)
                            .padding(.top, 9)
                    } label: {
                        Label("Raw input schema", systemImage: "curlybraces.square")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronInfo)
                    }
                    .tint(.tronInfo)
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

                Button {
                    Task {
                        await viewModel.invoke(
                            repository: repository,
                            connectionState: connectionState
                        )
                    }
                } label: {
                    HStack(spacing: 7) {
                        if viewModel.isMutating {
                            ProgressView().controlSize(.small).tint(.tronSurface)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("Invoke \(worker.toolName)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronSurface)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.tronEmerald, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canInvokeSelectedWorker)
                .opacity(viewModel.canInvokeSelectedWorker ? 1 : 0.45)

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

    private func triggers(_ inspection: WorkerInspectResultDTO) -> some View {
        WorkerConsoleSection(
            title: "Triggers",
            detail: "Server-owned routes that can dispatch this worker.",
            accent: .tronInfo
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
                            isMutating: viewModel.isMutating,
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
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(.tronWarning)
                            Text("Copy this token now. It is shown only from the rotation response.")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextSecondary)
                            WorkerMetadataRow(label: "Path", value: credential.path, isCode: true)
                            WorkerMetadataRow(label: "Token", value: credential.token, isCode: true)
                        }
                        .padding(11)
                        .sectionFill(.tronWarning, cornerRadius: 10, subtle: true, interactive: false)
                        .textSelection(.enabled)
                    }
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
                            isMutating: viewModel.isMutating
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
        WorkerConsoleSection(
            title: "Recent runs",
            detail: "Execution and delivery-attempt history from the durable worker queue.",
            accent: .tronCyan
        ) {
            if viewModel.runs.isEmpty {
                WorkerConsoleInlineEmptyState(symbol: "waveform.path", text: "No runs recorded yet.")
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.runs.prefix(20)) { run in
                        WorkerRunCard(run: run)
                    }
                }
            }
        }
    }

    private var inbox: some View {
        WorkerConsoleSection(
            title: "Durable inbox",
            detail: "Worker results and failures retained across reconnects.",
            accent: .tronAmber
        ) {
            if viewModel.inbox.isEmpty {
                WorkerConsoleInlineEmptyState(symbol: "tray", text: "No durable results are waiting.")
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.inbox.prefix(20)) { item in
                        WorkerInboxCard(item: item)
                    }
                }
            }
        }
    }

    private func audit(_ inspection: WorkerInspectResultDTO) -> some View {
        WorkerConsoleSection(
            title: "Audit history",
            detail: "Server-authored lifecycle evidence for this worker.",
            accent: .tronSlate
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
        WorkerConsoleSection(
            title: "Lifecycle",
            detail: worker.retired
                ? "Restore a retained version, or permanently remove this retired worker."
                : "Operational controls preserve durable state unless you explicitly retire the worker.",
            accent: worker.retired ? .tronWarning : .tronEmerald
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
                        isEnabled: !viewModel.isMutating,
                        action: { confirmPurge = true }
                    )
                } else {
                    if worker.enabled {
                        WorkerLifecycleButton(
                            title: "Stop current work",
                            symbol: "stop.circle",
                            color: .tronWarning,
                            isEnabled: !viewModel.isMutating
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
                        isEnabled: !viewModel.isMutating
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
                        isEnabled: !viewModel.isMutating,
                        action: { confirmRetire = true }
                    )
                }
            }
        }
    }
}

private struct WorkerConsoleSection<Content: View>: View {
    let title: String
    let detail: String
    let accent: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkerConsoleSectionHeader(title: title, detail: detail)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .sectionFill(accent, cornerRadius: 12, subtle: true, interactive: false)
        }
    }
}

private struct WorkerConsoleSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(detail)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WorkerMetadataRow: View {
    let label: String
    let value: String
    var isCode = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextMuted)
            Spacer(minLength: 8)
            Text(value)
                .font(
                    isCode
                        ? TronTypography.code(size: TronTypography.sizeCaption, weight: .medium)
                        : TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium)
                )
                .foregroundStyle(.tronTextPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }
}

private struct WorkerMetadataDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.tronBorder.opacity(0.6))
            .frame(height: 0.5)
    }
}

private struct WorkerSchemaFieldRow: View {
    let field: WorkerInputFieldPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(field.name)
                    .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(field.type)
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .medium))
                    .foregroundStyle(.tronInfo)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .glassEffect(.regular.tint(Color.tronInfo.opacity(0.15)), in: .capsule)
                if field.isRequired {
                    Text("required")
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(.tronWarning)
                }
                Spacer()
            }
            if let detail = field.detail, !detail.isEmpty {
                Text(detail)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .sectionFill(.tronInfo, cornerRadius: 9, subtle: true, interactive: false)
    }
}

private struct WorkerTriggerCard: View {
    let trigger: WorkerTriggerStatusDTO
    let isMutating: Bool
    let rotate: (() -> Void)?

    private var color: Color { trigger.enabled ? .tronInfo : .tronTextMuted }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: trigger.enabled ? "alarm.fill" : "alarm")
                    .foregroundStyle(color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkerConsolePresentation.displayLabel(trigger.triggerId))
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("\(WorkerConsolePresentation.displayLabel(trigger.kind)) · \(trigger.enabled ? "Enabled" : "Disabled")")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer()
                if trigger.tokenConfigured {
                    Label("Secured", systemImage: "lock.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(.tronSuccess)
                }
            }

            HStack(spacing: 10) {
                if let nextRun = WorkerConsolePresentation.timestamp(trigger.nextRunAt) {
                    Label(nextRun, systemImage: "calendar")
                }
                Label("Cursor \(trigger.streamCursor)", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)

            DisclosureGroup {
                WorkerJSONBlock(value: trigger.configuration, accent: color)
                    .padding(.top, 7)
            } label: {
                Text("Configuration")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(color)
            }
            .tint(color)

            if let rotate {
                Button("Rotate webhook token", action: rotate)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronInfo)
                    .disabled(isMutating)
            }
        }
        .padding(11)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: false)
    }
}

private struct WorkerVersionRow: View {
    let worker: WorkerSummaryDTO
    let version: WorkerVersionDTO
    let isMutating: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                .foregroundStyle(isActive ? .tronSuccess : .tronPurple)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(WorkerConsolePresentation.compactIdentifier(version.contentHash, length: 12))
                    .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                if let created = WorkerConsolePresentation.timestamp(version.createdAt) {
                    Text(created)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
            }
            Spacer()
            if let versionAction = WorkerVersionAction.resolve(worker: worker, version: version) {
                Button(versionAction.title, action: action)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(versionAction == .restore ? .tronEmerald : .tronPurple)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .glassEffect(
                        .regular.tint((versionAction == .restore ? Color.tronEmerald : .tronPurple).opacity(0.16)).interactive(),
                        in: .capsule
                    )
                    .buttonStyle(.plain)
                    .disabled(isMutating)
            } else {
                Text("Active")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronSuccess)
            }
        }
        .padding(.vertical, 8)
    }

    private var isActive: Bool {
        !worker.retired && version.version == worker.activeVersion
    }
}

private struct WorkerRunCard: View {
    let run: WorkerInvocationDTO

    private var color: Color {
        switch WorkerConsolePresentation.normalized(run.status) {
        case "completed", "succeeded": .tronSuccess
        case "failed", "cancelled": .tronError
        case "running": .tronCyan
        default: .tronWarning
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkerConsolePresentation.displayLabel(run.status))
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("\(WorkerConsolePresentation.displayLabel(run.triggerKind)) · \(run.attemptCount) attempt\(run.attemptCount == 1 ? "" : "s")")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer()
                if let timestamp = WorkerConsolePresentation.timestamp(run.completedAt ?? run.startedAt ?? run.createdAt) {
                    Text(timestamp)
                        .font(TronTypography.sans(size: TronTypography.sizeSM))
                        .foregroundStyle(.tronTextMuted)
                }
            }

            Text(WorkerConsolePresentation.compactIdentifier(run.invocationId, length: 16))
                .font(TronTypography.code(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)

            if let error = run.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Input")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                    WorkerJSONBlock(value: run.input, accent: color)
                    if let output = run.output {
                        Text("Output")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                        WorkerJSONBlock(value: output, accent: color)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Execution detail")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(color)
            }
            .tint(color)
        }
        .padding(11)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: false)
    }

    private var statusSymbol: String {
        switch WorkerConsolePresentation.normalized(run.status) {
        case "completed", "succeeded": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "cancelled": "stop.circle"
        case "running": "waveform.path.ecg"
        default: "clock"
        }
    }
}

private struct WorkerInboxCard: View {
    let item: WorkerInboxItemDTO

    private var color: Color {
        switch WorkerConsolePresentation.normalized(item.severity) {
        case "error", "critical": .tronError
        case "warning": .tronWarning
        default: .tronInfo
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: item.seen ? "tray" : "tray.full.fill")
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(WorkerConsolePresentation.displayLabel(item.severity))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                if !item.seen {
                    Text("New")
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(color)
                }
                Spacer()
                if let timestamp = WorkerConsolePresentation.timestamp(item.createdAt) {
                    Text(timestamp)
                        .font(TronTypography.sans(size: TronTypography.sizeSM))
                        .foregroundStyle(.tronTextMuted)
                }
            }
            WorkerJSONBlock(value: item.result, accent: color)
        }
        .padding(11)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: false)
    }
}

private struct WorkerAuditCard: View {
    let item: WorkerAuditDTO

    var body: some View {
        DisclosureGroup {
            WorkerJSONBlock(value: item.details, accent: .tronSlate)
                .padding(.top, 8)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "checklist")
                    .foregroundStyle(.tronSlate)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkerConsolePresentation.displayLabel(item.action))
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    if let timestamp = WorkerConsolePresentation.timestamp(item.createdAt) {
                        Text(timestamp)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
            }
        }
        .tint(.tronSlate)
        .padding(11)
        .sectionFill(.tronSlate, cornerRadius: 10, subtle: true, interactive: false)
    }
}

private struct WorkerJSONBlock: View {
    let value: AnyCodable
    let accent: Color

    var body: some View {
        WorkerCodeBlock(text: WorkerConsoleViewModel.prettyJSON(value), accent: accent)
    }
}

private struct WorkerCodeBlock: View {
    let text: String
    let accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(TronTypography.code(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
                .padding(9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(accent, cornerRadius: 8, subtle: true, compact: false, interactive: false)
    }
}

private struct WorkerLifecycleButton: View {
    let title: String
    let symbol: String
    let color: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .sectionFill(color, cornerRadius: 9, subtle: true, interactive: true)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct WorkerConsoleErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.tronError)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text("Worker state could not fully refresh")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(message)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(.tronError, cornerRadius: 10, subtle: true, interactive: false)
    }
}

private struct WorkerConsoleLoadingState: View {
    let title: String

    var body: some View {
        VStack(spacing: 9) {
            ProgressView().tint(.tronEmerald)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }
}

private struct WorkerConsoleEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(detail)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 18)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }
}

private struct WorkerConsoleInlineEmptyState: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
            .foregroundStyle(.tronTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .sectionFill(.tronSlate, cornerRadius: 9, subtle: true, interactive: false)
    }
}

private extension WorkerConsoleStatus {
    var color: Color {
        switch kind {
        case .healthy: .tronSuccess
        case .paused: .tronWarning
        case .retired: .tronTextMuted
        case .needsAttention: .tronError
        }
    }
}
