import SwiftUI

/// ViewModifier that applies all sheet-related modifiers to ChatView.
/// Extracted from ChatView body to help Swift type-checker.
@available(iOS 26.0, *)
struct ChatSheetModifier: ViewModifier {
    let sheetCoordinator: SheetCoordinator
    let viewModel: ChatViewModel
    let engineClient: EngineClient
    let sessionId: String
    let workspaceDeleted: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: sheetBinding, onDismiss: onDismiss) { sheet in
                ChatSheetContent(
                    sheet: sheet,
                    viewModel: viewModel,
                    engineClient: engineClient,
                    sessionId: sessionId,
                    workspaceDeleted: workspaceDeleted,
                    sheetCoordinator: sheetCoordinator
                )
            }
            .onChange(of: viewModel.showSettings) { _, show in
                if show, sheetCoordinator.activeSheet == nil {
                    sheetCoordinator.showSettings()
                }
            }
            .onChange(of: viewModel.userInteractionState.showSheet) { _, show in
                if show, sheetCoordinator.activeSheet == nil {
                    sheetCoordinator.showUserInteraction()
                } else if !show {
                    sheetCoordinator.dismissIfActive(.userInteraction)
                }
            }
    }

    private var sheetBinding: Binding<ChatSheet?> {
        Binding(
            get: { sheetCoordinator.activeSheet },
            set: { sheetCoordinator.activeSheet = $0 }
        )
    }

    private func onDismiss() {
        // Execute deferred submissions AFTER sheet dismiss animation completes.
        // These were prepared synchronously before dismiss() was called, ensuring
        // chip status updates are visible during the dismiss animation. The actual
        // prompt send (which triggers isProcessing, keyboard resign, etc.) happens
        // here to avoid concurrent state mutations that glitch the InputBar layout.
        viewModel.executePendingUserInteractionSubmission()

        viewModel.userInteractionState.showSheet = false
        viewModel.showSettings = false
        sheetCoordinator.onDismiss?()
    }
}

@available(iOS 26.0, *)
extension View {
    func chatSheets(
        coordinator: SheetCoordinator,
        viewModel: ChatViewModel,
        engineClient: EngineClient,
        sessionId: String,
        workspaceDeleted: Bool
    ) -> some View {
        modifier(ChatSheetModifier(
            sheetCoordinator: coordinator,
            viewModel: viewModel,
            engineClient: engineClient,
            sessionId: sessionId,
            workspaceDeleted: workspaceDeleted
        ))
    }
}
