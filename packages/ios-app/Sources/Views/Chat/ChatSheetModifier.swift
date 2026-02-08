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
            .onChange(of: viewModel.browserState.safariURL) { _, url in
                if let url = url, sheetCoordinator.activeSheet == nil {
                    sheetCoordinator.showSafari(url)
                }
            }
            .onChange(of: viewModel.browserState.showBrowserWindow) { _, show in
                if show {
                    if sheetCoordinator.activeSheet == nil {
                        sheetCoordinator.showBrowser()
                    }
                } else if sheetCoordinator.activeSheet == .browser {
                    sheetCoordinator.activeSheet = nil
                }
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
            .onChange(of: viewModel.uiCanvasState.showSheet) { _, show in
                if show, sheetCoordinator.activeSheet == nil {
                    sheetCoordinator.showUICanvas()
                }
            }
            .onChange(of: viewModel.todoState.showSheet) { _, show in
                if show, sheetCoordinator.activeSheet == nil {
                    sheetCoordinator.showTodoList()
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
        if sheetCoordinator.lastActiveSheet == .browser {
            if viewModel.browserState.autoDismissedBrowserThisTurn {
                viewModel.browserState.autoDismissedBrowserThisTurn = false
            } else {
                viewModel.userDismissedBrowser()
            }
        }
        viewModel.browserState.safariURL = nil
        viewModel.browserState.showBrowserWindow = false
        viewModel.askUserQuestionState.showSheet = false
        viewModel.subagentState.showDetailSheet = false
        viewModel.uiCanvasState.showSheet = false
        viewModel.todoState.showSheet = false
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
