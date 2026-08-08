import QuickLook
import SwiftUI
import UIKit

private enum ArtifactInboxLayout {
    static let horizontalInset: CGFloat = 20
    static let rowSpacing: CGFloat = 5
}

private struct ArtifactInboxRefreshKey: Equatable {
    let serverSelectionVersion: Int
    let continuity: EngineConnectionContinuity
}

private struct ArtifactPreviewRefreshKey: Equatable {
    let artifactId: String
    let continuity: EngineConnectionContinuity
}

struct ArtifactInboxView: View {
    let repository: any WorkerKernelRepository
    let continuity: EngineConnectionContinuity
    let serverSelectionVersion: Int
    @State private var viewModel = ArtifactInboxViewModel()
    @State private var selectedArtifact: WorkerArtifactDTO?
    @State private var projectionServerSelectionVersion: Int?

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

                if viewModel.artifacts.isEmpty,
                   !viewModel.isLoading,
                   !continuity.isConnected {
                    ContentUnavailableView {
                        Label("Reconnecting to artifacts", systemImage: "arrow.triangle.2.circlepath")
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBody,
                                weight: .semibold
                            ))
                    } description: {
                        Text("Your artifact inbox will refresh automatically when the paired server is available.")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(rowInsets)
                } else if viewModel.artifacts.isEmpty, !viewModel.isLoading {
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
                            startAgentSessionHandoff(.newArtifact)
                        }
                        .font(TronTypography.sans(
                            size: TronTypography.sizeBodySM,
                            weight: .semibold
                        ))
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
            .environment(\.defaultMinListRowHeight, 1)
            .contentMargins(.top, 15)
            .contentMargins(.bottom, 30)
            .refreshable {
                await viewModel.refresh(repository: repository)
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronEmerald)
        .task(id: ArtifactInboxRefreshKey(
            serverSelectionVersion: serverSelectionVersion,
            continuity: continuity
        )) {
            if projectionServerSelectionVersion != serverSelectionVersion {
                projectionServerSelectionVersion = serverSelectionVersion
                selectedArtifact = nil
                viewModel.deactivate()
            }
            guard continuity.isConnected else { return }
            await viewModel.refresh(repository: repository)
        }
        .onDisappear {
            viewModel.deactivate()
        }
        .sheet(item: $selectedArtifact) { artifact in
            ArtifactPreviewSheet(
                artifact: artifact,
                repository: repository,
                viewModel: viewModel,
                continuity: continuity,
                onDeleted: {
                    selectedArtifact = nil
                }
            )
        }
        .alert(
            "Artifact unavailable",
            isPresented: Binding(
                get: {
                    selectedArtifact == nil && viewModel.errorMessage != nil
                },
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
                    Text(artifact.displayName)
                        .font(TronTypography.sans(
                            size: TronTypography.sizeBody,
                            weight: .semibold
                        ))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: Int64(artifact.sizeBytes),
                            countStyle: .file
                        )
                    )
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the artifact")
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

/// Direct, verified artifact presentation.
///
/// The inbox row opens this content surface without an intermediary action
/// menu. Share and Delete live in the standard toolbar; the draft bridge is
/// shown only when a mounted interactive chat can actually receive it.
struct ArtifactPreviewSheet: View {
    let artifact: WorkerArtifactDTO
    let repository: any WorkerKernelRepository
    let viewModel: ArtifactInboxViewModel
    let continuity: EngineConnectionContinuity
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    @State private var deleteErrorMessage: String?

    private var content: MaterializedWorkerArtifact? {
        viewModel.materialized[artifact.id]
    }

    var body: some View {
        SettingsPageContainer(
            title: "Artifact",
            scrollsContent: false,
            leadingToolbar: {
                toolbarActions
            }
        ) {
            VStack(spacing: 0) {
                fileHeader
                Divider()
                    .overlay(Color.tronBorder.opacity(0.7))
                    .padding(.horizontal, ArtifactInboxLayout.horizontalInset)
                previewBody
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                continueInChatAction
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronEmerald)
        .task(id: ArtifactPreviewRefreshKey(
            artifactId: artifact.id,
            continuity: continuity
        )) {
            guard continuity.isConnected else { return }
            await viewModel.load(artifact, repository: repository)
        }
        .onDisappear {
            Task {
                await viewModel.release(artifact)
            }
        }
        .alert("Delete artifact?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    if await viewModel.delete(
                        artifact,
                        repository: repository
                    ) {
                        onDeleted()
                        dismiss()
                    } else if !Task.isCancelled {
                        deleteErrorMessage = viewModel.errorMessage
                            ?? "The engine did not confirm deletion."
                    }
                }
            }
        } message: {
            Text("This permanently removes the artifact from the engine and every client inbox.")
        }
        .alert(
            "Could not delete artifact",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        deleteErrorMessage = nil
                        viewModel.clearError()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private var toolbarActions: some View {
        if let url = content?.fileURL {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(.tronEmerald)
            }
            .accessibilityLabel("Share artifact")
        } else {
            Button {} label: {
                Image(systemName: "square.and.arrow.up")
                    .font(TronTypography.buttonSM)
            }
            .disabled(true)
            .accessibilityLabel("Share artifact unavailable")
        }
        SheetPrimaryActionButton(
            icon: "trash",
            accent: .tronError,
            isBusy: viewModel.deletingArtifactId == artifact.id,
            isEnabled: continuity.isConnected,
            accessibilityLabel: "Delete artifact"
        ) {
            showDeleteConfirmation = true
        }
    }

    private var fileHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(TronTypography.sans(size: TronTypography.sizeTitle))
                .foregroundStyle(.tronEmerald)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(artifact.displayName)
                    .font(TronTypography.sans(
                        size: TronTypography.sizeBody,
                        weight: .semibold
                    ))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    "\(artifact.mediaType)  ·  \(formattedSize)"
                )
                .font(TronTypography.code(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ArtifactInboxLayout.horizontalInset)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var previewBody: some View {
        if let content {
            ArtifactContentPreview(materialized: content)
        } else if viewModel.loadingArtifactId == artifact.id {
            SheetLoadingState(label: "Loading artifact")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !continuity.isConnected {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.tronEmerald)
                Text("Reconnecting to artifact")
                    .font(TronTypography.sans(
                        size: TronTypography.sizeTitle,
                        weight: .semibold
                    ))
                    .foregroundStyle(.tronTextPrimary)
                Text("The preview will resume automatically when the paired server is available.")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(TronTypography.sans(size: TronTypography.sizeXL))
                    .foregroundStyle(.tronWarning)
                Text("Artifact unavailable")
                    .font(TronTypography.sans(
                        size: TronTypography.sizeTitle,
                        weight: .semibold
                    ))
                    .foregroundStyle(.tronTextPrimary)
                Text(error)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task {
                        await viewModel.load(artifact, repository: repository)
                    }
                }
                .font(TronTypography.sans(
                    size: TronTypography.sizeBody,
                    weight: .semibold
                ))
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SheetLoadingState(label: "Preparing artifact")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var continueInChatAction: some View {
        if content != nil {
            Button {
                guard let attachment = viewModel.attachment(for: artifact) else {
                    return
                }
                startAgentSessionHandoff(.artifact(
                    displayName: artifact.displayName,
                    attachment: attachment
                ))
                dismiss()
            } label: {
                Label(
                    "Continue in New Chat",
                    systemImage: "bubble.left.and.text.bubble.right.fill"
                )
                .font(TronTypography.sans(
                    size: TronTypography.sizeBodySM,
                    weight: .semibold
                ))
                .foregroundStyle(.tronEmerald)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular.tint(Color.tronPhthaloGreen.opacity(0.16)),
                in: Capsule()
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(artifact.sizeBytes),
            countStyle: .file
        )
    }
}

private struct ArtifactContentPreview: View {
    let materialized: MaterializedWorkerArtifact

    private var preview: ArtifactPreviewContent {
        ArtifactPreviewContent.resolve(
            mediaType: materialized.artifact.mediaType,
            displayName: materialized.artifact.displayName,
            data: materialized.data
        )
    }

    @ViewBuilder
    var body: some View {
        switch preview {
        case .markdown(let text):
            ScrollView {
                TextContentView(text: text, role: .assistant)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text, let monospaced):
            ArtifactReadOnlyTextView(text: text, monospaced: monospaced)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .quickLook:
            ArtifactQuickLookView(url: materialized.fileURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ArtifactReadOnlyTextView: UIViewRepresentable {
    let text: String
    let monospaced: Bool

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.font = TronTypography.uiFont(
            mono: monospaced,
            size: TronTypography.sizeBody
        )
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(
            top: 16,
            left: 16,
            bottom: 32,
            right: 16
        )
        textView.textContainer.lineFragmentPadding = 0
        TronScrollEdgeEffects.applySoft(to: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        textView.font = TronTypography.uiFont(
            mono: monospaced,
            size: TronTypography.sizeBody
        )
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
