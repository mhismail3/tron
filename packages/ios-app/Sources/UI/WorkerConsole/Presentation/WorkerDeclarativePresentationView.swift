import SwiftUI

private struct WorkerPresentationArtifactSelection: Identifiable {
    let pointer: String
    var id: String { pointer }
}

private enum WorkerPresentationLoadResult: Sendable {
    case success(String, WorkerResultChunkDTO)
    case failure(String)
    case deferred
}

/// Generic native renderer for a worker's immutable presentation descriptor.
///
/// Bound values are hydrated only through the existing bounded result reader.
/// Links remain HTTPS-only and actions can invoke only the owning worker with
/// its bundle-declared, server-validated fixed input.
struct WorkerRunDeclarativePresentationView: View {
    let graph: WorkerRunGraphDTO
    let repository: any WorkerKernelRepository

    @Environment(\.dependencies) private var dependencies

    @State private var chunks: [String: WorkerResultChunkDTO] = [:]
    @State private var loadFailures: Set<String> = []
    @State private var actionMessages: [String: String] = [:]
    @State private var activeActionIds: Set<String> = []
    @State private var artifactSelection: WorkerPresentationArtifactSelection?
    @State private var pendingConfirmation: WorkerPresentationSectionDTO?
    @State private var loadedInvocationId: String?

    private var descriptor: WorkerPresentationDTO? {
        WorkerDeclarativePresentation.descriptor(for: graph)
    }

    private var owningWorkerId: String {
        graph.nodes.first {
            $0.invocationId == graph.requestedInvocationId
        }?.workerId ?? graph.workerId
    }

    var body: some View {
        if WorkerRunGraphPresentation.canInspectResult(status: graph.status),
           let descriptor {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(descriptor.sections.prefix(24))) { section in
                    if WorkerDeclarativePresentation.kind(of: section) != nil {
                        sectionView(section)
                    }
                }
            }
            .accessibilityIdentifier("worker-declarative-presentation")
            .task(id: WorkerPresentationRefreshKey(
                invocationId: graph.requestedInvocationId,
                continuity: dependencies.connectionRepository.continuity
            )) {
                await loadResultBindings(descriptor)
            }
            .sheet(item: $artifactSelection) { selection in
                WorkerResultInspectorSheet(
                    invocationId: graph.requestedInvocationId,
                    repository: repository,
                    initialPointer: selection.pointer
                )
            }
            .confirmationDialog(
                pendingConfirmation?.title ?? "Confirm worker action",
                isPresented: Binding(
                    get: { pendingConfirmation != nil },
                    set: { if !$0 { pendingConfirmation = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingConfirmation
            ) { section in
                if let action = section.action {
                    Button(action.label) {
                        pendingConfirmation = nil
                        invoke(action)
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingConfirmation = nil
                }
            } message: { section in
                Text(section.detail ?? "Run this fixed worker action?")
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: WorkerPresentationSectionDTO) -> some View {
        switch WorkerDeclarativePresentation.kind(of: section) {
        case .text:
            boundSection(section, accent: .tronCyan) { value in
                if let text = WorkerDeclarativePresentation.primitiveText(value) {
                    Text(text)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    unavailableValue
                }
            }
        case .status:
            boundSection(section, accent: statusColor(section)) { value in
                if let text = WorkerDeclarativePresentation.primitiveText(value) {
                    Label(text, systemImage: statusSymbol(text))
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(statusColor(text))
                } else {
                    unavailableValue
                }
            }
        case .progress:
            boundSection(section, accent: .tronPurple) { value in
                if let progress = WorkerDeclarativePresentation.progressValue(value) {
                    VStack(alignment: .leading, spacing: 7) {
                        ProgressView(value: progress)
                            .tint(.tronPurple)
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(.tronTextSecondary)
                    }
                } else {
                    unavailableValue
                }
            }
        case .table:
            boundSection(section, accent: .tronInfo) { value in
                table(value, columns: section.columns)
            }
        case .list:
            boundSection(section, accent: .tronEmerald) { value in
                let items = WorkerDeclarativePresentation.listItems(value)
                if items.isEmpty {
                    unavailableValue
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle()
                                    .fill(Color.tronEmerald)
                                    .frame(width: 5, height: 5)
                                Text(item)
                                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                                    .foregroundStyle(.tronTextPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        case .link:
            staticSection(section, accent: .tronInfo) {
                if let url = WorkerDeclarativePresentation.safeURL(section.url),
                   let label = section.label {
                    Link(destination: url) {
                        Label(label, systemImage: "safari")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.tronInfo)
                } else {
                    unavailableValue
                }
            }
        case .artifact:
            staticSection(section, accent: .tronPurple) {
                if let pointer = section.valuePointer,
                   chunks[pointer] != nil,
                   let label = section.label {
                    WorkerRunDisclosureRow(
                        title: label,
                        detail: "Open this bounded path in the generic durable result inspector.",
                        symbol: "doc.text.magnifyingglass",
                        accent: .tronPurple
                    ) {
                        artifactSelection = WorkerPresentationArtifactSelection(pointer: pointer)
                    }
                } else if let pointer = section.valuePointer,
                          !loadFailures.contains(pointer) {
                    loadingValue
                } else {
                    unavailableValue
                }
            }
        case .confirmation:
            actionSection(section, confirmationRequired: true)
        case .workerAction:
            actionSection(section, confirmationRequired: false)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func boundSection<Content: View>(
        _ section: WorkerPresentationSectionDTO,
        accent: Color,
        @ViewBuilder content: @escaping (AnyCodable) -> Content
    ) -> some View {
        staticSection(section, accent: accent) {
            if let pointer = section.valuePointer,
               let chunk = chunks[pointer] {
                content(chunk.value)
            } else if let pointer = section.valuePointer,
                      !loadFailures.contains(pointer) {
                loadingValue
            } else {
                unavailableValue
            }
        }
    }

    private func staticSection<Content: View>(
        _ section: WorkerPresentationSectionDTO,
        accent: Color,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        WorkerConsoleSection(
            title: section.title
                ?? WorkerConsolePresentation.displayLabel(section.kind),
            detail: section.detail ?? "Native view of the validated durable worker result.",
            accent: accent,
            content: content
        )
    }

    private func actionSection(
        _ section: WorkerPresentationSectionDTO,
        confirmationRequired: Bool
    ) -> some View {
        staticSection(section, accent: confirmationRequired ? .tronWarning : .tronEmerald) {
            VStack(alignment: .leading, spacing: 9) {
                if let action = section.action {
                    Button {
                        if confirmationRequired {
                            pendingConfirmation = section
                        } else {
                            invoke(action)
                        }
                    } label: {
                        HStack {
                            Label(
                                action.label,
                                systemImage: confirmationRequired
                                    ? "checkmark.shield"
                                    : "play.circle"
                            )
                            Spacer()
                            if activeActionIds.contains(action.actionId) {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(confirmationRequired ? .tronWarning : .tronEmerald)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!activeActionIds.isEmpty)
                    if let message = actionMessages[action.actionId] {
                        Text(message)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                    }
                } else {
                    unavailableValue
                }
            }
        }
    }

    @ViewBuilder
    private func table(
        _ value: AnyCodable,
        columns: [WorkerPresentationColumnDTO]
    ) -> some View {
        let rows = WorkerDeclarativePresentation.tableRows(value, columns: columns)
        if rows.isEmpty || columns.isEmpty {
            unavailableValue
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            Text(column.label)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                                .foregroundStyle(.tronTextMuted)
                                .frame(minWidth: 96, alignment: .leading)
                        }
                    }
                    .padding(.bottom, 7)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            WorkerMetadataDivider()
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                Text(value)
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                    .foregroundStyle(.tronTextPrimary)
                                    .frame(minWidth: 96, alignment: .leading)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }

    private var loadingValue: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading result field…")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
        }
    }

    private var unavailableValue: some View {
        Label("This result field is unavailable.", systemImage: "questionmark.circle")
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextSecondary)
    }

    private func loadResultBindings(_ presentation: WorkerPresentationDTO) async {
        if loadedInvocationId != graph.requestedInvocationId {
            chunks = [:]
            loadedInvocationId = graph.requestedInvocationId
        }
        loadFailures = []
        let pointers = WorkerDeclarativePresentation.resultPointers(in: presentation)
        let requests: [Task<WorkerPresentationLoadResult, Never>] = pointers.map { pointer in
            Task { @MainActor in
                do {
                    return WorkerPresentationLoadResult.success(
                        pointer,
                        try await repository.workerResult(
                            invocationId: graph.requestedInvocationId,
                            pointer: pointer,
                            offset: 0,
                            limit: 20
                        )
                    )
                } catch where ConnectionErrorClassifier.isTransientTransport(error) {
                    return .deferred
                } catch {
                    return WorkerPresentationLoadResult.failure(pointer)
                }
            }
        }
        await withTaskCancellationHandler {
            for request in requests {
                guard !Task.isCancelled else { return }
                switch await request.value {
                case .success(let pointer, let chunk):
                    chunks[pointer] = chunk
                case .failure(let pointer):
                    loadFailures.insert(pointer)
                case .deferred:
                    break
                }
            }
        } onCancel: {
            for request in requests {
                request.cancel()
            }
        }
        for request in requests {
            request.cancel()
        }
    }

    private func invoke(_ action: WorkerPresentationActionDTO) {
        guard activeActionIds.isEmpty else { return }
        activeActionIds.insert(action.actionId)
        actionMessages[action.actionId] = nil
        Task {
            defer { activeActionIds.remove(action.actionId) }
            do {
                let result = try await repository.invokeWorker(
                    workerId: owningWorkerId,
                    input: action.input,
                    idempotencyKey: .userAction("worker.presentation.\(action.actionId)")
                )
                actionMessages[action.actionId] = result.status == "completed"
                    ? "Action completed."
                    : "Action accepted."
            } catch {
                actionMessages[action.actionId] =
                    "Action failed: \(error.localizedDescription)"
            }
        }
    }

    private func statusSymbol(_ value: String) -> String {
        switch WorkerConsolePresentation.normalized(value) {
        case "complete", "completed", "healthy", "ready", "success", "succeeded":
            "checkmark.circle.fill"
        case "failed", "error", "blocked":
            "exclamationmark.triangle.fill"
        case "pending", "queued", "running", "working":
            "clock.fill"
        default:
            "info.circle.fill"
        }
    }

    private func statusColor(_ section: WorkerPresentationSectionDTO) -> Color {
        guard let pointer = section.valuePointer,
              let chunk = chunks[pointer],
              let value = WorkerDeclarativePresentation.primitiveText(chunk.value) else {
            return .tronInfo
        }
        return statusColor(value)
    }

    private func statusColor(_ value: String) -> Color {
        switch WorkerConsolePresentation.normalized(value) {
        case "complete", "completed", "healthy", "ready", "success", "succeeded":
            .tronSuccess
        case "failed", "error", "blocked":
            .tronError
        case "pending", "queued", "running", "working":
            .tronWarning
        default:
            .tronInfo
        }
    }
}

private struct WorkerPresentationRefreshKey: Equatable {
    let invocationId: String
    let continuity: EngineConnectionContinuity
}
