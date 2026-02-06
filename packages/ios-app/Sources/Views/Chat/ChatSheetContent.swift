import SwiftUI

/// Renders the appropriate sheet content based on ChatSheet enum case.
/// Isolates sheet content from main view body to aid Swift type-checking.
/// This view is used with a single .sheet(item:) modifier in ChatView.
@available(iOS 26.0, *)
struct ChatSheetContent: View {
    let sheet: ChatSheet
    let viewModel: ChatViewModel
    let rpcClient: RPCClient
    let sessionId: String
    let skillStore: SkillStore?
    let workspaceDeleted: Bool
    @Environment(\.dependencies) var dependencies

    // Convenience accessor
    private var eventStoreManager: EventStoreManager { dependencies!.eventStoreManager }

    var body: some View {
        sheetContent
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch sheet {
        case .safari(let url):
            SafariView(url: url)

        case .browser:
            browserSheet

        case .settings:
            SettingsView()
                .environment(\.dependencies, dependencies)

        case .contextAudit:
            ContextAuditView(
                rpcClient: rpcClient,
                sessionId: sessionId,
                skillStore: skillStore,
                readOnly: workspaceDeleted
            )

        case .sessionHistory:
            SessionHistorySheet(
                sessionId: sessionId,
                rpcClient: rpcClient,
                eventStoreManager: eventStoreManager
            )

        case .skillDetail(let skill, let mode):
            skillDetailSheet(skill: skill, mode: mode)

        case .compactionDetail(let data):
            CompactionDetailSheet(
                tokensBefore: data.tokensBefore,
                tokensAfter: data.tokensAfter,
                reason: data.reason,
                summary: data.summary
            )
            .adaptivePresentationDetents([.medium, .large])

        case .memoryDetail(let data):
            MemoryDetailSheet(
                title: data.title,
                entryType: data.entryType,
                sessionId: data.sessionId,
                rpcClient: rpcClient
            )
            .adaptivePresentationDetents([.medium, .large])

        case .askUserQuestion:
            askUserQuestionSheet

        case .subagentDetail:
            subagentDetailSheet

        case .uiCanvas:
            UICanvasSheet(state: viewModel.uiCanvasState)

        case .todoList:
            TodoDetailSheet(
                rpcClient: rpcClient,
                sessionId: sessionId,
                workspaceId: viewModel.workspaceId,
                todoState: viewModel.todoState
            )

        case .notifyApp(let data):
            NotifyAppDetailSheet(data: data)

        case .thinkingDetail(let content):
            ThinkingDetailSheet(content: content)

        case .commandToolDetail(let data):
            CommandToolDetailSheet(data: data)

        case .adaptDetail(let data):
            AdaptDetailSheet(data: data)

        case .modelPicker:
            ModelPickerSheet(
                models: viewModel.modelPickerState.cachedModels,
                currentModelId: viewModel.modelPickerState.displayModelName(current: viewModel.currentModel),
                onSelect: { model in
                    NotificationCenter.default.post(name: .modelPickerAction, object: model)
                }
            )
        }
    }

    // MARK: - Sheet Builders

    @ViewBuilder
    private var browserSheet: some View {
        BrowserSheetView(
            frameImage: viewModel.browserState.browserFrame,
            currentUrl: viewModel.browserState.browserStatus?.currentUrl,
            isStreaming: viewModel.browserState.browserStatus?.isStreaming ?? false,
            onCloseBrowser: {
                viewModel.userDismissedBrowser()
            }
        )
    }

    @ViewBuilder
    private func skillDetailSheet(skill: Skill, mode: ChipMode) -> some View {
        if let store = skillStore {
            SkillDetailSheet(skill: skill, skillStore: store, mode: mode)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var askUserQuestionSheet: some View {
        if let data = viewModel.askUserQuestionState.currentData {
            AskUserQuestionSheet(
                toolData: data,
                onSubmit: { answers in
                    Task {
                        await viewModel.submitAskUserQuestionAnswers(answers)
                    }
                },
                onDismiss: {
                    viewModel.dismissAskUserQuestionSheet()
                },
                readOnly: data.status == .answered
            )
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var subagentDetailSheet: some View {
        if let data = viewModel.subagentState.selectedSubagent {
            SubagentDetailSheet(
                data: data,
                subagentState: viewModel.subagentState,
                eventStoreManager: eventStoreManager,
                onSendResults: { subagent in
                    viewModel.sendSubagentResults(subagent)
                }
            )
            .adaptivePresentationDetents([.medium, .large])
        } else {
            EmptyView()
        }
    }
}
