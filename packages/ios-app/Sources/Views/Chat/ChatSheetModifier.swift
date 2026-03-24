import SwiftUI

/// ViewModifier that applies all sheet-related modifiers to ChatView.
/// Extracted from ChatView body to help Swift type-checker.
@available(iOS 26.0, *)
struct ChatSheetModifier: ViewModifier {
    let sheetCoordinator: SheetCoordinator
    let viewModel: ChatViewModel
    let rpcClient: RPCClient
    let sessionId: String
    let skillStore: SkillStore?
    let workspaceDeleted: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: sheetBinding, onDismiss: onDismiss) { sheet in
                ChatSheetContent(
                    sheet: sheet,
                    viewModel: viewModel,
                    rpcClient: rpcClient,
                    sessionId: sessionId,
                    skillStore: skillStore,
                    workspaceDeleted: workspaceDeleted,
                    sheetCoordinator: sheetCoordinator
                )
            }
            .onChange(of: viewModel.showSettings) { _, show in
                if show, sheetCoordinator.activeSheet == nil {
                    sheetCoordinator.showSettings()
                }
            }
            .onChange(of: viewModel.askUserQuestionState.showSheet) { _, show in
                if show, sheetCoordinator.activeSheet == nil {
                    sheetCoordinator.showAskUserQuestion()
                }
            }
            .onChange(of: viewModel.subagentState.showDetailSheet) { _, show in
                if show, sheetCoordinator.activeSheet == nil {
                    sheetCoordinator.showSubagentDetail()
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
        viewModel.askUserQuestionState.showSheet = false
        viewModel.subagentState.showDetailSheet = false
        viewModel.showSettings = false
        sheetCoordinator.onDismiss?()
    }
}

@available(iOS 26.0, *)
extension View {
    func chatSheets(
        coordinator: SheetCoordinator,
        viewModel: ChatViewModel,
        rpcClient: RPCClient,
        sessionId: String,
        skillStore: SkillStore?,
        workspaceDeleted: Bool
    ) -> some View {
        modifier(ChatSheetModifier(
            sheetCoordinator: coordinator,
            viewModel: viewModel,
            rpcClient: rpcClient,
            sessionId: sessionId,
            skillStore: skillStore,
            workspaceDeleted: workspaceDeleted
        ))
    }
}
