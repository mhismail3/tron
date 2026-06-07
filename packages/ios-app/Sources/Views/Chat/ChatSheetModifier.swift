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
    }

    private var sheetBinding: Binding<ChatSheet?> {
        Binding(
            get: { sheetCoordinator.activeSheet },
            set: { sheetCoordinator.activeSheet = $0 }
        )
    }

    private func onDismiss() {
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
