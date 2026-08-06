import QuickLook
import SwiftUI
import UniformTypeIdentifiers

private enum ArtifactInboxLayout {
    static let horizontalInset: CGFloat = 20
    static let rowSpacing: CGFloat = 5
}

struct ArtifactInboxView: View {
    let repository: any WorkerKernelRepository
    let draftSessionId: String?
    @State private var viewModel = ArtifactInboxViewModel()
    @State private var selectedArtifact: WorkerArtifactDTO?

    var body: some View {
        SettingsPageContainer(title: "Artifacts", scrollsContent: false) {
            List {
                if let attention = viewModel.storageAttention,
                   attention.requiresAttention {
                    storageAttentionCard(attention)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(rowInsets)
                }

                if viewModel.artifacts.isEmpty, !viewModel.isLoading {
                    ContentUnavailableView {
                        Label("No artifacts yet", systemImage: "tray.full")
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBody,
                                weight: .semibold
                            ))
                    } description: {
                        Text("Documents and files delivered by workers will remain here until you delete them.")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    } actions: {
                        Button("Create through chat") {
                            guard let draftSessionId else { return }
                            NotificationCenter.default.post(
                                name: .createArtifactInChat,
                                object: ArtifactChatDraftRequest(
                                    sessionId: draftSessionId,
                                    prompt: "Create a document artifact for me. Ask what content and format I need before generating it."
                                )
                            )
                        }
                        .font(TronTypography.sans(
                            size: TronTypography.sizeBodySM,
                            weight: .semibold
                        ))
                        .disabled(draftSessionId == nil)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(rowInsets)
                } else {
                    ForEach(viewModel.artifacts) { artifact in
                        artifactRow(artifact)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(rowInsets)
                            .task {
                                await viewModel.loadMoreIfNeeded(
                                    current: artifact,
                                    repository: repository
                                )
                            }
                    }
                }

                if viewModel.isLoading || viewModel.isLoadingMore {
                    SheetLoadingState(
                        label: viewModel.isLoading
                            ? "Loading artifacts"
                            : "Loading more artifacts"
                    )
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable {
                await viewModel.refresh(repository: repository)
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronEmerald)
        .task {
            await viewModel.refresh(repository: repository)
        }
        .onDisappear {
            viewModel.deactivate()
        }
        .sheet(item: $selectedArtifact) { artifact in
            ArtifactDetailView(
                artifact: artifact,
                repository: repository,
                viewModel: viewModel,
                draftSessionId: draftSessionId,
                onDeleted: {
                    selectedArtifact = nil
                }
            )
        }
        .alert(
            "Artifact unavailable",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.clearError()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(
            top: ArtifactInboxLayout.rowSpacing,
            leading: ArtifactInboxLayout.horizontalInset,
            bottom: ArtifactInboxLayout.rowSpacing,
            trailing: ArtifactInboxLayout.horizontalInset
        )
    }

    private func artifactRow(_ artifact: WorkerArtifactDTO) -> some View {
        Button {
            selectedArtifact = artifact
        } label: {
            SettingsCard(accent: .tronEmerald, interactive: true) {
                HStack(spacing: 12) {
                    Image(systemName: icon(for: artifact.mediaType))
                        .font(TronTypography.sans(size: TronTypography.sizeTitle))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artifact.displayName)
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBody,
                                weight: .semibold
                            ))
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(1)
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: Int64(artifact.sizeBytes),
                                countStyle: .file
                            )
                        )
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
        .buttonStyle(.plain)
    }

    private func storageAttentionCard(
        _ attention: WorkerArtifactStorageAttentionDTO
    ) -> some View {
        SettingsCard(accent: .tronWarning) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.tronWarning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Engine storage needs attention")
                        .font(TronTypography.sans(
                            size: TronTypography.sizeBody,
                            weight: .semibold
                        ))
                    Text(attention.message ?? "Delete artifacts you no longer need.")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                }
            }
            .padding(12)
        }
    }

    private func icon(for mediaType: String) -> String {
        if mediaType == "application/pdf" { return "doc.richtext" }
        if mediaType.hasPrefix("image/") { return "photo" }
        if mediaType.contains("spreadsheet") || mediaType == "text/csv" {
            return "tablecells"
        }
        if mediaType.contains("presentation") { return "rectangle.on.rectangle" }
        return "doc.text"
    }
}

private struct ArtifactDetailView: View {
    let artifact: WorkerArtifactDTO
    let repository: any WorkerKernelRepository
    let viewModel: ArtifactInboxViewModel
    let draftSessionId: String?
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    @State private var showPreview = false
    @State private var showExporter = false
    @State private var exportDocument = ArtifactExportDocument(data: Data())
    @State private var attachedToDraft = false

    private var content: MaterializedWorkerArtifact? {
        viewModel.materialized[artifact.id]
    }

    var body: some View {
        SettingsPageContainer(title: "Artifact") {
            VStack(alignment: .leading, spacing: 16) {
                metadataCard
                actionsCard
            }
        }
        .workerConsoleSheetPresentation()
        .task(id: artifact.id) {
            await viewModel.load(artifact, repository: repository)
        }
        .onDisappear {
            Task {
                await viewModel.release(artifact)
            }
        }
        .sheet(isPresented: $showPreview) {
            if let url = content?.fileURL {
                ArtifactPreviewSheet(artifact: artifact, url: url)
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: artifact.displayName
        ) { _ in }
        .alert("Delete artifact?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                viewModel.delete(artifact, repository: repository)
                onDeleted()
                dismiss()
            }
        } message: {
            Text("This permanently removes the artifact from the engine and every client inbox.")
        }
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "File")
            SettingsCard(accent: .tronEmerald) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(artifact.displayName)
                        .font(TronTypography.sans(
                            size: TronTypography.sizeBody,
                            weight: .semibold
                        ))
                    Text(artifact.mediaType)
                        .font(TronTypography.code(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: Int64(artifact.sizeBytes),
                            countStyle: .file
                        )
                    )
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Actions")
            SettingsCard {
                VStack(spacing: 0) {
                    actionButton("Preview", icon: "eye", enabled: content != nil) {
                        showPreview = true
                    }
                    divider
                    if let url = content?.fileURL {
                        ShareLink(item: url) {
                            actionLabel("Share", icon: "square.and.arrow.up")
                        }
                        .buttonStyle(.plain)
                    } else {
                        actionLabel("Share", icon: "square.and.arrow.up")
                            .opacity(0.4)
                    }
                    divider
                    actionButton("Export", icon: "folder.badge.plus", enabled: content != nil) {
                        guard let content else { return }
                        exportDocument = ArtifactExportDocument(data: content.data)
                        showExporter = true
                    }
                    divider
                    actionButton(
                        attachedToDraft ? "Attached to Draft" : "Attach to Draft",
                        icon: attachedToDraft ? "checkmark.circle.fill" : "paperclip",
                        enabled: content != nil
                            && draftSessionId != nil
                            && !attachedToDraft
                    ) {
                        guard let draftSessionId,
                              let attachment = viewModel.attachment(for: artifact) else { return }
                        NotificationCenter.default.post(
                            name: .attachArtifactToDraft,
                            object: ArtifactDraftAttachmentRequest(
                                sessionId: draftSessionId,
                                attachment: attachment
                            )
                        )
                        attachedToDraft = true
                    }
                    divider
                    actionButton(
                        "Delete",
                        icon: "trash",
                        accent: .tronError,
                        enabled: viewModel.deletingArtifactId != artifact.id
                    ) {
                        showDeleteConfirmation = true
                    }
                }
            }
        }
    }

    private var divider: some View {
        Divider().padding(.leading, 42)
    }

    private func actionButton(
        _ title: String,
        icon: String,
        accent: Color = .tronEmerald,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            actionLabel(title, icon: icon, accent: accent)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func actionLabel(
        _ title: String,
        icon: String,
        accent: Color = .tronEmerald
    ) -> some View {
        SettingsRow(icon: icon, label: title, accentColor: accent) {
            if viewModel.loadingArtifactId == artifact.id {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var exportType: UTType {
        let pathExtension = URL(fileURLWithPath: artifact.displayName).pathExtension
        return UTType(filenameExtension: pathExtension) ?? .data
    }
}

/// Standard Tron presentation around Quick Look's native artifact renderer.
///
/// Quick Look owns the format-specific content surface, while this sheet owns
/// navigation, dismissal, sharing, safe-area layout, and detent behavior. Keep
/// the controller out of `ignoresSafeArea()` so it cannot cover sheet chrome.
private struct ArtifactPreviewSheet: View {
    let artifact: WorkerArtifactDTO
    let url: URL

    var body: some View {
        SettingsPageContainer(title: "Preview", scrollsContent: false) {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(.tronEmerald)
            }
            .accessibilityLabel("Share artifact")
        } content: {
            ArtifactQuickLookView(url: url)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    previewCaption
                }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronEmerald)
    }

    private var previewCaption: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(.tronEmerald)
            Text(artifact.displayName)
                .font(TronTypography.sans(
                    size: TronTypography.sizeCaption,
                    weight: .medium
                ))
                .foregroundStyle(.tronTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(
                ByteCountFormatter.string(
                    fromByteCount: Int64(artifact.sizeBytes),
                    countStyle: .file
                )
            )
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassEffect(
            .regular.tint(Color.tronPhthaloGreen.opacity(0.18)),
            in: Capsule()
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

private struct ArtifactExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct ArtifactQuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = ArtifactQuickLookController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: QLPreviewController,
        context: Context
    ) {
        context.coordinator.url = url
        uiViewController.reloadData()
        TronScrollEdgeEffects.applySoftToDescendantScrollViews(
            of: uiViewController.view
        )
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in _: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }

    private final class ArtifactQuickLookController: QLPreviewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            TronScrollEdgeEffects.applySoftToDescendantScrollViews(of: view)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            TronScrollEdgeEffects.applySoftToDescendantScrollViews(of: view)
        }
    }
}
