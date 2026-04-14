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
    let sheetCoordinator: SheetCoordinator?
    @Environment(\.dependencies) var dependencies

    // Convenience accessor
    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }

    private var sheetReadOnly: Bool {
        SheetReadOnlyPolicy.isReadOnly(workspaceDeleted: workspaceDeleted, agentPhase: viewModel.agentPhase)
    }

    var body: some View {
        sheetContent
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch sheet {
        case .settings:
            SettingsView()
                .environment(\.dependencies, dependencies)

        case .contextAudit:
            ContextAuditView(
                rpcClient: rpcClient,
                sessionId: sessionId,
                skillStore: skillStore,
                readOnly: sheetReadOnly,
                contextState: viewModel.contextState,
                currentModelInfo: viewModel.modelPickerState.currentModelInfo(current: viewModel.currentModel),
                reasoningLevel: viewModel.modelPickerState.currentModelInfo(current: viewModel.currentModel)?.supportsReasoning == true ? viewModel.inputBarState.reasoningLevel : nil,
                availableModels: viewModel.modelPickerState.cachedModels,
                currentModelId: viewModel.modelPickerState.displayModelName(current: viewModel.currentModel)
            )

        case .session:
            SessionSheet(
                rpcClient: rpcClient,
                sessionId: sessionId,
                onAskAgent: { message in
                    viewModel.pendingSourceChangesPrompt = message
                    sheetCoordinator?.dismiss()
                }
            )

        case .skillDetail(let skill, let mode):
            skillDetailSheet(skill: skill, mode: mode)

        case .compactionDetail(let data):
            CompactionDetailSheet(
                tokensBefore: data.tokensBefore,
                tokensAfter: data.tokensAfter,
                reason: data.reason,
                summary: data.summary,
                preservedTurns: data.preservedTurns,
                summarizedTurns: data.summarizedTurns
            )
            .adaptivePresentationDetents([.medium, .large])

        case .memoryRetainDetail(let data):
            MemoryRetainDetailSheet(title: data.title, summary: data.summary)
                .adaptivePresentationDetents([.medium, .large])

        case .askUserQuestion:
            askUserQuestionSheet

        case .getConfirmation:
            getConfirmationSheet

        case .subagentDetail:
            subagentDetailSheet

        case .subagentResultsList:
            subagentResultsListSheet

        case .notifyApp(let data):
            NotifyAppDetailSheet(data: data)

        case .thinkingDetail(let content):
            ThinkingDetailSheet(
                state: ThinkingDetailState(
                    thinkingState: viewModel.thinkingState,
                    staticContent: content
                )
            )

        case .commandToolDetail(let data):
            commandToolDetailSheet(fallback: data)

        case .providerErrorDetail(let data):
            ProviderErrorDetailSheet(data: data)
                .adaptivePresentationDetents([.medium])

        case .modelPicker:
            ModelPickerSheet(
                models: viewModel.modelPickerState.cachedModels,
                currentModelId: viewModel.modelPickerState.displayModelName(current: viewModel.currentModel),
                readOnly: sheetReadOnly,
                reasoningLevel: viewModel.inputBarState.reasoningLevel,
                onSelect: { model in
                    NotificationCenter.default.post(name: .modelPickerAction, object: model)
                }
            )

        }
    }

    // MARK: - Sheet Builders

    @ViewBuilder
    private func commandToolDetailSheet(fallback: CommandToolChipData) -> some View {
        // Look up live data from viewModel.messages so streaming output updates in real-time
        let liveData: CommandToolChipData = {
            if let index = MessageFinder.lastIndexOfToolUse(toolCallId: fallback.id, in: viewModel.messages),
               case .toolUse(let tool) = viewModel.messages[index].content {
                return CommandToolChipData(from: tool)
            }
            return fallback
        }()
        switch liveData.normalizedName {
        case "read":
            ReadToolDetailSheet(data: liveData)
        case "write":
            WriteToolDetailSheet(data: liveData)
        case "edit":
            EditToolDetailSheet(data: liveData)
        case "bash":
            BashToolDetailSheet(data: liveData, rpcClient: rpcClient, sessionId: sessionId)
        case "wait":
            WaitToolDetailSheet(data: liveData, viewModel: viewModel, rpcClient: rpcClient, sessionId: sessionId)
        case "glob", "find":
            GlobToolDetailSheet(data: liveData)
        case "search":
            SearchToolDetailSheet(data: liveData)
        case "webfetch":
            WebFetchToolDetailSheet(data: liveData)
        case "websearch":
            WebSearchToolDetailSheet(data: liveData)
        case "computeruse":
            ComputerUseToolDetailSheet(data: liveData)
        case "display":
            DisplayToolDetailSheet(data: liveData)
        case "mcpsearch":
            McpSearchToolDetailSheet(data: liveData)
        case "mcpcall":
            McpCallToolDetailSheet(data: liveData)
        case "managejob":
            ManageJobToolDetailSheet(data: liveData)
        default:
            CommandToolDetailSheet(data: liveData, onOpenURL: { _ in })
        }
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
                    viewModel.prepareAskUserQuestionSubmission(answers)
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
    private var getConfirmationSheet: some View {
        if let data = viewModel.getConfirmationState.currentData {
            GetConfirmationSheet(
                toolData: data,
                onSubmit: { decision, note in
                    viewModel.prepareGetConfirmationSubmission(decision, note: note)
                },
                onDismiss: {
                    viewModel.dismissGetConfirmationSheet()
                },
                readOnly: data.status == .approved || data.status == .denied
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
                rpcClient: rpcClient,
                onSendResults: { _ in
                    viewModel.deliverSubagentResults()
                    sheetCoordinator?.dismiss()
                }
            )
            .adaptivePresentationDetents([.medium, .large])
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var subagentResultsListSheet: some View {
        let pending = viewModel.subagentState.pendingSubagents
        SubagentResultsListSheet(
            pendingSubagents: pending,
            subagentState: viewModel.subagentState,
            eventStoreManager: eventStoreManager,
            rpcClient: rpcClient,
            onSendAll: {
                viewModel.deliverSubagentResults()
                sheetCoordinator?.dismiss()
            },
            onSendIndividual: { _ in
                viewModel.deliverSubagentResults()
                sheetCoordinator?.dismiss()
            }
        )
        .adaptivePresentationDetents([.medium, .large])
    }
}
