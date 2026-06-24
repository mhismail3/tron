import SwiftUI

/// ViewModifier that applies all sheet-related modifiers to ChatView.
/// Extracted from ChatView body to help Swift type-checker.
struct ChatSheetModifier: ViewModifier {
    let sheetCoordinator: SheetCoordinator
    let viewModel: ChatViewModel
    let sessionId: String
    let workspaceDeleted: Bool

    func body(content: Content) -> some View {
        let observedActiveSheet = sheetCoordinator.activeSheet
        content
            .sheet(item: sheetBinding(observedActiveSheet), onDismiss: onDismiss) { sheet in
                ChatSheetContent(
                    sheet: sheet,
                    viewModel: viewModel,
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
    }

    private func sheetBinding(_ observedActiveSheet: ChatSheet?) -> Binding<ChatSheet?> {
        Binding(
            get: { observedActiveSheet },
            set: { sheetCoordinator.activeSheet = $0 }
        )
    }

    private func onDismiss() {
        viewModel.showSettings = false
        sheetCoordinator.onDismiss?()
    }
}

extension View {
    func chatSheets(
        coordinator: SheetCoordinator,
        viewModel: ChatViewModel,
        sessionId: String,
        workspaceDeleted: Bool
    ) -> some View {
        modifier(ChatSheetModifier(
            sheetCoordinator: coordinator,
            viewModel: viewModel,
            sessionId: sessionId,
            workspaceDeleted: workspaceDeleted
        ))
    }
}
