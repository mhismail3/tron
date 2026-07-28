import SwiftUI

/// On-demand protocol and durable-identity evidence for one worker run.
struct WorkerRunTechnicalDetailsSheet: View {
    let run: WorkerInvocationDTO
    let graph: WorkerRunGraphDTO?

    @State private var showInput = false
    @State private var showLegacyOutput = false
    @State private var showTechnicalTimeline = false

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
                VStack(alignment: .leading, spacing: 16) {
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
            .sheet(isPresented: $showTechnicalTimeline) {
                WorkerTextDetailSheet(
                    title: "Technical Timeline",
                    values: technicalTimelineValues,
                    accent: .tronSlate
                )
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
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
}
