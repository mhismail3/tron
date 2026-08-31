import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Route-only presentation shell. All authority and task admission remain in
/// ChatView/ChatSessionPresentation; this modifier owns no mirrored state.
struct ChatRoutes: ViewModifier {
    let sessionID: String
    let projectCWD: String?
    let onForkCreated: (AppModel.SessionNavigationRoute) -> Void
    @Binding var showContext: Bool
    @Binding var showSettings: Bool
    @Binding var queuedMessageEditor: QueuedMessageEditorRoute?
    let installed: InstalledChatTranscript?
    let mutatingQueuedMessageIDs: Set<String>
    let onUpdateQueuedMessage: (
        String,
        String,
        SessionSnapshot.QueuedMessage.Behavior
    ) -> Void
    let onRemoveQueuedMessage: (String) -> Void
    @Binding var cameraPresented: Bool
    @Binding var photosPresented: Bool
    @Binding var photos: [PhotosPickerItem]
    let onCameraImage: (UIImage) -> Void
    @Binding var processesPresented: Bool
    @Binding var interaction: ExtensionInteraction?
    let onInteractionClosed: (ExtensionInteraction) -> Void
    @Binding var filesPresented: Bool
    let onFileImport: (Result<[URL], Error>) -> Void
    @Binding var editorRequest: ComposerEditorRequest?
    let onUseEditorRequest: (ComposerEditorRequest) -> Void
    let onKeepEditorRequest: (ComposerEditorRequest) -> Void

    func body(content: Content) -> some View {
        content
            .tronManagedSheet(
                isPresented: $showContext,
                identity: "chat.\(sessionID).context"
            ) {
                SessionContextSheet(sessionID: sessionID, onForkCreated: onForkCreated)
            }
            .tronManagedSheet(
                isPresented: $showSettings,
                identity: "chat.\(sessionID).settings"
            ) {
                SettingsView(
                    scope: .project,
                    projectSessionID: sessionID,
                    projectCWD: projectCWD,
                    onImported: { route in
                        showSettings = false
                        onForkCreated(route)
                    }
                )
                .presentationDragIndicator(.hidden)
            }
            .tronManagedSheet(
                item: $queuedMessageEditor,
                identity: { "chat.\(sessionID).queue.\($0.id)" }
            ) { route in
                if let commit = QueuedMessageManagementPolicy.installedCommit(for: installed),
                   let message = commit.items.first(where: { $0.id == route.id }) {
                    QueuedMessageEditorSheet(
                        message: message,
                        isSaving: mutatingQueuedMessageIDs.contains(message.id),
                        onSave: { text, behavior in
                            onUpdateQueuedMessage(message.id, text, behavior)
                        },
                        onDelete: { onRemoveQueuedMessage(message.id) }
                    )
                } else {
                    QueueEditingUnavailableSheet()
                }
            }
            .tronManagedSheet(
                isPresented: $cameraPresented,
                identity: "chat.\(sessionID).camera"
            ) {
                CameraCaptureSheet(onImageCaptured: onCameraImage)
            }
            .photosPicker(
                isPresented: $photosPresented,
                selection: $photos,
                maxSelectionCount: ChatAttachmentImportPolicy.maximumPhotoSelection,
                matching: .images
            )
            .tronManagedSystemPresentation(
                isPresented: $photosPresented,
                identity: "chat.\(sessionID).photos"
            )
            .tronManagedSheet(
                isPresented: $processesPresented,
                identity: "chat.\(sessionID).processes"
            ) {
                SessionProcessesSheet(sessionID: sessionID)
            }
            .tronManagedSheet(
                item: $interaction,
                identity: { "chat.\(sessionID).interaction.\($0.id)" }
            ) { value in
                if value.method == .form {
                    ExtensionFormSheet(
                        sessionID: sessionID,
                        interaction: value,
                        onResolved: { onInteractionClosed(value) },
                        onLocallyClosed: { onInteractionClosed(value) }
                    )
                } else {
                    ExtensionInteractionSheet(
                        sessionID: sessionID,
                        interaction: value,
                        onResolved: { onInteractionClosed(value) },
                        onLocallyClosed: { onInteractionClosed(value) }
                    )
                }
            }
            .fileImporter(
                isPresented: $filesPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: onFileImport
            )
            .tronManagedSystemPresentation(
                isPresented: $filesPresented,
                identity: "chat.\(sessionID).files"
            )
            .tronManagedSheet(
                item: $editorRequest,
                identity: { "chat.\(sessionID).editor.\($0.id)" }
            ) { request in
                TronConfirmationSheet(
                    title: ComposerEditorRequestPolicy.confirmationTitle,
                    message: ComposerEditorRequestPolicy.confirmationMessage,
                    confirmTitle: ComposerEditorRequestPolicy.useActionTitle,
                    secondaryTitle: ComposerEditorRequestPolicy.keepActionTitle,
                    icon: "square.and.pencil",
                    onConfirm: { onUseEditorRequest(request) },
                    onSecondary: { onKeepEditorRequest(request) }
                )
            }
    }
}

private struct QueueEditingUnavailableSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(TronTypography.sans(size: 28, weight: .semibold))
                    .foregroundStyle(Color.tronAmber)
                    .accessibilityHidden(true)
                Text("Queue Editing Unavailable")
                    .font(TronTypography.sheetSectionHeader)
                    .foregroundStyle(Color.tronTextPrimary)
                Text("Queue management is no longer available for this Gateway commit.")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tronBackground)
            .accessibilityElement(children: .combine)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Queued Message", accent: .tronAmber)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }
}
