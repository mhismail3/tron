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
            .sheet(isPresented: $showContext) {
                SessionContextSheet(sessionID: sessionID, onForkCreated: onForkCreated)
            }
            .sheet(isPresented: $showSettings) {
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
            .sheet(item: $queuedMessageEditor) { route in
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
                    ContentUnavailableView(
                        "Queue Editing Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(
                            "Queue management is no longer available for this Gateway commit."
                        )
                    )
                }
            }
            .sheet(isPresented: $cameraPresented) {
                CameraCaptureSheet(onImageCaptured: onCameraImage)
            }
            .photosPicker(
                isPresented: $photosPresented,
                selection: $photos,
                maxSelectionCount: ChatAttachmentImportPolicy.maximumPhotoSelection,
                matching: .images
            )
            .sheet(isPresented: $processesPresented) {
                SessionProcessesSheet(sessionID: sessionID)
            }
            .sheet(item: $interaction) { value in
                if value.questionnaire != nil {
                    ExtensionQuestionnaireSheet(
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
            .sheet(item: $editorRequest) { request in
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
