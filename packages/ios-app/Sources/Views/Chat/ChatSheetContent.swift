import SwiftUI

/// Renders the appropriate sheet content based on ChatSheet enum case.
/// Isolates sheet content from main view body to aid Swift type-checking.
/// This view is used with a single .sheet(item:) modifier in ChatView.
@available(iOS 26.0, *)
struct ChatSheetContent: View {
    let sheet: ChatSheet
    let viewModel: ChatViewModel
    let engineClient: EngineClient
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
            SettingsView { server in
                viewModel.showSettings = false
                sheetCoordinator?.activeSheet = nil
                ServerOnboardingLauncher.post(prefill: server)
            }
                .environment(\.dependencies, dependencies)

        case .agentControl:
            AgentControlView(
                engineClient: engineClient,
                sessionId: sessionId,
                skillStore: skillStore,
                readOnly: sheetReadOnly,
                contextState: viewModel.contextState,
                currentModelInfo: viewModel.modelPickerState.currentModelInfo(current: viewModel.currentModel),
                reasoningLevel: viewModel.modelPickerState.currentModelInfo(current: viewModel.currentModel)?.supportsReasoning == true ? viewModel.inputBarState.reasoningLevel : nil,
                availableModels: viewModel.modelPickerState.cachedModels,
                currentModelId: viewModel.modelPickerState.displayModelName(current: viewModel.currentModel),
                onAskAgent: { message in
                    viewModel.pendingSourceChangesPrompt = message
                    sheetCoordinator?.dismiss()
                },
                gitWorkflowState: viewModel.gitWorkflowState,
                onWorktreeStatusShouldRefresh: { [weak viewModel] in
                    await viewModel?.requestWorktreeStatus()
                }
            )

        case .skillDetail(let skill):
            skillDetailSheet(skill: skill)

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

        case .engineApproval:
            engineApprovalSheet

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

        case .capabilityInvocationDetail(let data):
            capabilityInvocationDetailSheet(snapshot: data)

        case .providerErrorDetail(let data):
            ProviderErrorDetailSheet(data: data)
                .adaptivePresentationDetents([.medium])

        }
    }

    // MARK: - Sheet Builders

    @ViewBuilder
    private func capabilityInvocationDetailSheet(snapshot: CapabilityInvocationData) -> some View {
        let liveData: CapabilityInvocationData = {
            if let index = MessageFinder.lastIndexOfCapabilityInvocation(id: snapshot.id, in: viewModel.messages),
               case .capabilityInvocation(let invocation) = viewModel.messages[index].content {
                return invocation
            }
            return snapshot
        }()
        CapabilityInvocationDetailSheet(data: liveData)
    }

    @ViewBuilder
    private func skillDetailSheet(skill: Skill) -> some View {
        if let store = skillStore {
            SkillDetailSheet(skill: skill, skillStore: store)
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
    private var engineApprovalSheet: some View {
        if let data = viewModel.engineApprovalState.currentData {
            EngineApprovalSheet(
                toolData: data,
                onSubmit: { decision, note in
                    viewModel.prepareEngineApprovalSubmission(decision, note: note)
                },
                onDismiss: {
                    viewModel.dismissEngineApprovalSheet()
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
                engineClient: engineClient,
                onSendResults: { _ in
                    viewModel.deliverSubagentResults(idempotencyKey: .userAction("agent.deliverSubagentResults"))
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
            engineClient: engineClient,
            onSendAll: {
                viewModel.deliverSubagentResults(idempotencyKey: .userAction("agent.deliverSubagentResults"))
                sheetCoordinator?.dismiss()
            },
            onSendIndividual: { _ in
                viewModel.deliverSubagentResults(idempotencyKey: .userAction("agent.deliverSubagentResults"))
                sheetCoordinator?.dismiss()
            }
        )
        .adaptivePresentationDetents([.medium, .large])
    }
}
