import SwiftUI

/// On-demand protocol and durable-identity evidence for one worker run.
struct WorkerRunTechnicalDetailsSheet: View {
    let run: WorkerInvocationDTO
    let graph: WorkerRunGraphDTO?

    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var showInput = false
    @State private var showLegacyOutput = false
    @State private var showRawResult = false
    @State private var showTechnicalTimeline = false
    @State private var resultChunk: WorkerResultChunkDTO?
    @State private var isLoadingResult = false
    @State private var resultLoadError: String?
    @State private var resultLoadGeneration = 0
    @State private var projectionOwnerId: UUID?

    init(
        run: WorkerInvocationDTO,
        graph: WorkerRunGraphDTO?,
        initialResultChunk: WorkerResultChunkDTO? = nil
    ) {
        self.run = run
        self.graph = graph
        _resultChunk = State(initialValue: initialResultChunk)
    }

    private var technicalTimelineValues: [String] {
        graph?.timeline
            .filter(\.technical)
            .map {
                let timestamp = WorkerConsolePresentation.timestamp($0.occurredAt) ?? $0.occurredAt
                return "\(timestamp) · \($0.summary)"
            } ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    WorkerConsoleSection(
                        title: "Protocol values",
                        detail: "Raw worker values are available only on demand.",
                        accent: .tronInfo
                    ) {
                        VStack(spacing: 0) {
                            disclosure(
                                title: "Worker input",
                                detail: "Exact typed input admitted by the kernel.",
                                symbol: "arrow.down.doc"
                            ) {
                                showInput = true
                            }
                            if let resultChunk {
                                WorkerMetadataDivider()
                                disclosure(
                                    title: "Validated result JSON",
                                    detail: resultChunk.truncated
                                        ? "Open the bounded root result page."
                                        : "Open or copy the exact root result.",
                                    symbol: "curlybraces"
                                ) {
                                    showRawResult = true
                                }
                            } else if isLoadingResult {
                                WorkerMetadataDivider()
                                HStack(spacing: 9) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading validated result evidence…")
                                        .font(TronTypography.sans(
                                            size: TronTypography.sizeCaption
                                        ))
                                        .foregroundStyle(.tronTextSecondary)
                                }
                                .padding(.vertical, 9)
                            } else if let resultLoadError {
                                WorkerMetadataDivider()
                                Text("Validated result could not load: \(resultLoadError)")
                                    .font(TronTypography.sans(
                                        size: TronTypography.sizeCaption
                                    ))
                                    .foregroundStyle(.tronWarning)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.vertical, 9)
                            }
                            if run.output?.legacyInline != nil {
                                WorkerMetadataDivider()
                                disclosure(
                                    title: "Legacy result evidence",
                                    detail: "Inline result retained for migration compatibility.",
                                    symbol: "doc.text"
                                ) {
                                    showLegacyOutput = true
                                }
                            }
                            if !technicalTimelineValues.isEmpty {
                                WorkerMetadataDivider()
                                disclosure(
                                    title: "Technical timeline",
                                    detail: "\(technicalTimelineValues.count) internal event summaries.",
                                    symbol: "terminal"
                                ) {
                                    showTechnicalTimeline = true
                                }
                            }
                        }
                    }

                    WorkerConsoleSection(
                        title: "Durable identity",
                        detail: "Immutable invocation and result ownership evidence.",
                        accent: .tronSlate
                    ) {
                        VStack(spacing: 0) {
                            metadata(
                                "Invocation",
                                run.invocationId,
                                length: 18
                            )
                            WorkerMetadataDivider()
                            metadata("Version", run.workerVersion, length: 12)
                            if let reference = run.output?.reference {
                                WorkerMetadataDivider()
                                WorkerMetadataRow(
                                    label: "Result size",
                                    value: ByteCountFormatter.string(
                                        fromByteCount: Int64(clamping: reference.sizeBytes),
                                        countStyle: .file
                                    )
                                )
                                WorkerMetadataDivider()
                                metadata("Content digest", reference.contentSha256, length: 16)
                                WorkerMetadataDivider()
                                metadata(
                                    "Output schema",
                                    reference.outputSchemaSha256,
                                    length: 16
                                )
                            }
                            if let graph {
                                WorkerMetadataDivider()
                                WorkerMetadataRow(
                                    label: "Critical path",
                                    value: WorkerRunGraphPresentation.elapsed(
                                        graph.timing.criticalPathMs
                                    )
                                )
                                WorkerMetadataDivider()
                                WorkerMetadataRow(
                                    label: "Model time",
                                    value: WorkerRunGraphPresentation.elapsed(graph.timing.modelMs)
                                )
                            }
                        }
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Run Details", color: .tronSlate)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronSlate)
                }
            }
            .sheet(isPresented: $showInput) {
                WorkerJSONDetailSheet(
                    title: "Worker Input",
                    value: run.input,
                    accent: .tronInfo
                )
            }
            .sheet(isPresented: $showLegacyOutput) {
                if let output = run.output?.legacyInline {
                    WorkerJSONDetailSheet(
                        title: "Legacy Worker Result",
                        value: output,
                        accent: .tronSlate
                    )
                }
            }
            .sheet(isPresented: $showRawResult) {
                if let resultChunk {
                    WorkerJSONDetailSheet(
                        title: "Validated Worker Result",
                        value: resultChunk.value,
                        accent: .tronSuccess
                    )
                }
            }
            .sheet(isPresented: $showTechnicalTimeline) {
                WorkerTextDetailSheet(
                    title: "Technical Timeline",
                    values: technicalTimelineValues,
                    accent: .tronSlate
                )
            }
            .task(id: WorkerRunTechnicalResultRefreshKey(
                invocationId: run.output?.reference?.invocationId,
                continuity: dependencies.connectionRepository.continuity
            )) {
                let ownerId = dependencies.connectionRepository.continuityOwnerId
                if let projectionOwnerId, projectionOwnerId != ownerId {
                    dismiss()
                    return
                }
                projectionOwnerId = ownerId
                await loadResultIfNeeded()
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronSlate)
    }

    private func disclosure(
        title: String,
        detail: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        WorkerRunDisclosureRow(
            title: title,
            detail: detail,
            symbol: symbol,
            accent: .tronInfo,
            action: action
        )
    }

    private func metadata(_ label: String, _ value: String, length: Int) -> some View {
        WorkerMetadataRow(
            label: label,
            value: WorkerConsolePresentation.compactIdentifier(value, length: length),
            isCode: true
        )
    }

    private func loadResultIfNeeded() async {
        guard let reference = run.output?.reference,
              resultChunk?.reference.invocationId != reference.invocationId else {
            return
        }
        resultLoadGeneration &+= 1
        let generation = resultLoadGeneration
        isLoadingResult = true
        resultLoadError = nil
        defer {
            if generation == resultLoadGeneration {
                isLoadingResult = false
            }
        }
        do {
            let loaded = try await dependencies.workerKernelRepository.workerResult(
                invocationId: reference.invocationId,
                pointer: "",
                offset: 0,
                limit: 20
            )
            guard !Task.isCancelled,
                  generation == resultLoadGeneration else { return }
            resultChunk = loaded
        } catch {
            guard generation == resultLoadGeneration else { return }
            if ConnectionErrorClassifier.isTransientTransport(error) {
                return
            }
            resultLoadError = error.localizedDescription
        }
    }
}

private struct WorkerRunTechnicalResultRefreshKey: Equatable {
    let invocationId: String?
    let continuity: EngineConnectionContinuity
}
