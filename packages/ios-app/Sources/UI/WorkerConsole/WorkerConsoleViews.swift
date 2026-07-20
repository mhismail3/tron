import SwiftUI

struct WorkerConsoleDashboardBand: View {
    let viewModel: WorkerConsoleViewModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(.tronEmerald)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Workers")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("\(viewModel.healthyCount) healthy · \(viewModel.workers.count) persistent")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer()
                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tronTextMuted)
                }
            }
            .padding(13)
            .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open worker console")
    }
}

struct WorkerConsoleSheet: View {
    @Bindable var viewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository
    let connectionState: ConnectionState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(viewModel.stopAll ? "Resume all queued work" : "Stop all workers") {
                        Task {
                            await viewModel.setStopAll(
                                !viewModel.stopAll,
                                repository: repository,
                                connectionState: connectionState
                            )
                        }
                    }
                    .foregroundStyle(viewModel.stopAll ? .tronEmerald : .tronError)
                    .disabled(viewModel.isMutating)
                } footer: {
                    Text("Stop-all blocks new dispatch, cancels active work, and stops resident services. Durable queued work stays visible.")
                }

                if let error = viewModel.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.tronError)
                    }
                }

                Section("Persistent workers") {
                    if viewModel.workers.isEmpty {
                        Text("No workers yet. Create one conversationally with Tron.")
                            .foregroundStyle(.tronTextSecondary)
                    }
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
            .navigationTitle("Worker Console")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            await viewModel.refresh(
                                repository: repository,
                                connectionState: connectionState
                            )
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isRefreshing)
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
            .task {
                await viewModel.refresh(repository: repository, connectionState: connectionState)
            }
            .task {
                await viewModel.monitor(repository: repository, connectionState: connectionState)
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
    }

    private var selectedWorkerPresented: Binding<Bool> {
        Binding(
            get: { viewModel.selectedWorkerId != nil },
            set: { if !$0 { viewModel.selectedWorkerId = nil } }
        )
    }
}

private struct WorkerConsoleRow: View {
    let worker: WorkerSummaryDTO

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: worker.enabled ? "bolt.circle.fill" : "pause.circle")
                .foregroundStyle(worker.enabled ? .tronSuccess : .tronTextMuted)
            VStack(alignment: .leading, spacing: 3) {
                Text(worker.name)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text("\(worker.runnerKind) · \(worker.health) · v\(worker.activeVersion.prefix(8))")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                Text(worker.description)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(2)
            }
            Spacer()
            if worker.triggerCount > 0 {
                Text("\(worker.triggerCount)")
                    .countBadge(.tronInfo)
            }
            Image(systemName: "chevron.right")
                .foregroundStyle(.tronTextMuted)
        }
        .contentShape(Rectangle())
    }
}

private struct WorkerDetailSheet: View {
    @Bindable var viewModel: WorkerConsoleViewModel
    let repository: any WorkerKernelRepository
    let connectionState: ConnectionState
    @State private var confirmPurge = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let worker = viewModel.selectedWorker {
                        overview(worker)
                        invocation(worker)
                        triggers
                        versions(worker)
                        recentRuns
                        inbox
                        audit
                        lifecycle(worker)
                    }
                }
                .padding(18)
            }
            .navigationTitle(viewModel.selectedWorker?.name ?? "Worker")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
            .confirmationDialog(
                "Permanently purge this retired worker?",
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
            }
        }
        .adaptivePresentationDetents([.large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
    }

    private func overview(_ worker: WorkerSummaryDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(worker.description).foregroundStyle(.tronTextPrimary)
            Text("Tool: \(worker.toolName)")
            Text("Runner: \(worker.runnerKind)")
            Text("Health: \(worker.health)")
            Text("Active version: \(worker.activeVersion)")
            if let provenance = viewModel.inspection?.bundle["provenance"] {
                Text("Provenance: \(WorkerConsoleViewModel.prettyJSON(provenance))")
                    .textSelection(.enabled)
            }
        }
        .font(TronTypography.sans(size: TronTypography.sizeCaption))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func invocation(_ worker: WorkerSummaryDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Typed invocation").font(.headline)
            if let schema = viewModel.inspection?.bundle["inputSchema"] {
                Text(WorkerConsoleViewModel.prettyJSON(schema))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            TextEditor(text: $viewModel.invocationInput)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 100)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            Button("Invoke \(worker.toolName)") {
                Task {
                    await viewModel.invoke(
                        repository: repository,
                        connectionState: connectionState
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!worker.enabled || viewModel.isMutating)
            if let result = viewModel.invocationResult {
                Text(result)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var triggers: some View {
        if let inspection = viewModel.inspection, !inspection.triggers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Triggers").font(.headline)
                ForEach(inspection.triggers) { trigger in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(trigger.triggerId).font(.subheadline.weight(.semibold))
                            Text("\(trigger.kind) · \(trigger.enabled ? "enabled" : "disabled")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if trigger.kind == "webhook" {
                            Button("Rotate token") {
                                Task {
                                    await viewModel.rotateWebhook(
                                        triggerId: trigger.triggerId,
                                        repository: repository,
                                        connectionState: connectionState
                                    )
                                }
                            }
                        }
                    }
                }
                if let credential = viewModel.webhookCredential {
                    Text("\(credential.path)\n\(credential.token)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func versions(_ worker: WorkerSummaryDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Versions").font(.headline)
            ForEach(viewModel.inspection?.versions ?? []) { version in
                HStack {
                    Text(String(version.version.prefix(12)))
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    if version.version != worker.activeVersion {
                        Button("Rollback") {
                            Task {
                                await viewModel.rollback(
                                    to: version.version,
                                    repository: repository,
                                    connectionState: connectionState
                                )
                            }
                        }
                    } else {
                        Text("active").foregroundStyle(.tronSuccess)
                    }
                }
            }
        }
    }

    private var recentRuns: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runs").font(.headline)
            ForEach(viewModel.runs.prefix(20)) { run in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(run.status) · \(run.triggerKind)")
                        .font(.subheadline.weight(.semibold))
                    Text(run.invocationId).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let error = run.error { Text(error).font(.caption).foregroundStyle(.tronError) }
                }
            }
        }
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Durable inbox").font(.headline)
            ForEach(viewModel.inbox.prefix(20)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.severity) · \(item.createdAt)")
                        .font(.subheadline.weight(.semibold))
                    Text(WorkerConsoleViewModel.prettyJSON(item.result))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var audit: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audit history").font(.headline)
            ForEach((viewModel.inspection?.audit ?? []).prefix(20)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.action) · \(item.createdAt)")
                        .font(.subheadline.weight(.semibold))
                    Text(WorkerConsoleViewModel.prettyJSON(item.details))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func lifecycle(_ worker: WorkerSummaryDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lifecycle").font(.headline)
            Button(worker.enabled ? "Disable and stop" : "Enable") {
                Task {
                    await viewModel.setEnabled(
                        !worker.enabled,
                        repository: repository,
                        connectionState: connectionState
                    )
                }
            }
            .buttonStyle(.bordered)
            if !worker.retired {
                Button("Retire", role: .destructive) {
                    Task {
                        await viewModel.retire(
                            repository: repository,
                            connectionState: connectionState
                        )
                    }
                }
            } else {
                Button("Purge permanently", role: .destructive) { confirmPurge = true }
            }
        }
    }
}
