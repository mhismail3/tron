import SwiftUI

struct WorkerResultSelection: Identifiable {
    let invocationId: String
    var id: String { invocationId }
}

private struct WorkerResultLocation: Hashable {
    let pointer: String
    let offset: UInt64
}

/// On-demand, bounded reader for the exact durable result owned by the server.
///
/// Navigation never accumulates an unbounded local copy. Each path or page is
/// fetched independently and the integrity-bound reference remains visible.
struct WorkerResultInspectorSheet: View {
    let invocationId: String
    let repository: any WorkerKernelRepository

    @State private var locations = [WorkerResultLocation(pointer: "", offset: 0)]
    @State private var chunk: WorkerResultChunkDTO?
    @State private var isLoading = false
    @State private var error: String?

    private var location: WorkerResultLocation {
        locations.last ?? WorkerResultLocation(pointer: "", offset: 0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let chunk {
                        referenceSummary(chunk.reference)
                        resultValue(chunk)
                        resultChildren(chunk)
                        resultNavigation(chunk)
                        technicalReference(chunk.reference)
                    } else if let error {
                        WorkerConsoleErrorBanner(message: error)
                    } else {
                        ProgressView("Loading exact durable result…")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Worker Result", color: .tronSuccess)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if locations.count > 1 {
                        Button {
                            locations.removeLast()
                        } label: {
                            Image(systemName: "arrow.backward")
                        }
                        .accessibilityLabel("Previous result path or page")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronSuccess)
                }
            }
            .task(id: "\(invocationId)|\(location.pointer)|\(location.offset)") {
                await load()
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronSuccess)
    }

    private func referenceSummary(_ reference: WorkerResultReferenceDTO) -> some View {
        WorkerConsoleSection(
            title: location.pointer.isEmpty ? "Exact result" : "Exact result path",
            detail: location.pointer.isEmpty
                ? "Loaded from the durable invocation on demand."
                : location.pointer,
            accent: .tronSuccess
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(reference.preview)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(byteCount(reference.sizeBytes), systemImage: "externaldrive")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }
        }
    }

    @ViewBuilder
    private func resultValue(_ chunk: WorkerResultChunkDTO) -> some View {
        if !chunk.value.isNull {
            WorkerConsoleSection(
                title: chunk.truncated ? "Result page" : "Result value",
                detail: chunk.truncated
                    ? "\(chunk.returned) of \(chunk.total) values from server truth."
                    : "Schema-validated JSON at the selected path.",
                accent: .tronCyan
            ) {
                WorkerJSONBlock(value: chunk.value, accent: .tronCyan)
            }
        }
    }

    @ViewBuilder
    private func resultChildren(_ chunk: WorkerResultChunkDTO) -> some View {
        if !chunk.children.isEmpty {
            WorkerConsoleSection(
                title: "Result fields",
                detail: "Open only the field needed; large parent objects remain out of memory.",
                accent: .tronPurple
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(chunk.children.enumerated()), id: \.element.id) { index, child in
                        if index > 0 {
                            WorkerMetadataDivider()
                        }
                        Button {
                            locations.append(
                                WorkerResultLocation(pointer: child.pointer, offset: 0)
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(child.pointer, systemImage: "doc.text.magnifyingglass")
                                    .font(TronTypography.sans(
                                        size: TronTypography.sizeBodySM,
                                        weight: .semibold
                                    ))
                                    .foregroundStyle(.tronTextPrimary)
                                Text("\(WorkerConsolePresentation.displayLabel(child.type)) · \(byteCount(child.sizeBytes))")
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                    .foregroundStyle(.tronTextSecondary)
                                if !child.preview.isEmpty {
                                    Text(child.preview)
                                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                        .foregroundStyle(.tronTextMuted)
                                        .lineLimit(3)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resultNavigation(_ chunk: WorkerResultChunkDTO) -> some View {
        if let nextOffset = chunk.nextOffset {
            Button {
                locations.append(
                    WorkerResultLocation(pointer: chunk.pointer, offset: nextOffset)
                )
            } label: {
                Label("Load next result page", systemImage: "arrow.forward.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .sectionFill(.tronCyan, cornerRadius: 10, subtle: true, interactive: true)
        }
    }

    private func technicalReference(_ reference: WorkerResultReferenceDTO) -> some View {
        WorkerConsoleSection(
            title: "Technical reference",
            detail: "Integrity and immutable-version evidence.",
            accent: .tronSlate
        ) {
            VStack(spacing: 0) {
                WorkerMetadataRow(
                    label: "Invocation",
                    value: WorkerConsolePresentation.compactIdentifier(
                        reference.invocationId,
                        length: 18
                    ),
                    isCode: true
                )
                WorkerMetadataDivider()
                WorkerMetadataRow(
                    label: "Version",
                    value: WorkerConsolePresentation.compactIdentifier(
                        reference.workerVersion,
                        length: 12
                    ),
                    isCode: true
                )
                WorkerMetadataDivider()
                WorkerMetadataRow(
                    label: "Content",
                    value: WorkerConsolePresentation.compactIdentifier(
                        reference.contentSha256,
                        length: 18
                    ),
                    isCode: true
                )
                WorkerMetadataDivider()
                WorkerMetadataRow(
                    label: "Schema",
                    value: WorkerConsolePresentation.compactIdentifier(
                        reference.outputSchemaSha256,
                        length: 18
                    ),
                    isCode: true
                )
            }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            chunk = try await repository.workerResult(
                invocationId: invocationId,
                pointer: location.pointer,
                offset: location.offset,
                limit: 20
            )
        } catch {
            chunk = nil
            self.error = "Exact worker result could not load: \(error.localizedDescription)"
        }
    }

    private func byteCount(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(value, UInt64(Int64.max))),
            countStyle: .file
        )
    }
}
