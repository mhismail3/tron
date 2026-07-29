import SwiftUI

/// Renders the appropriate sheet content based on ChatSheet enum case.
/// Isolates sheet content from main view body to aid Swift type-checking.
/// This view is used with a single .sheet(item:) modifier in ChatView.
struct ChatSheetContent: View {
    let sheet: ChatSheet
    let viewModel: ChatViewModel
    let sessionId: String
    let sheetCoordinator: SheetCoordinator?
    @Environment(\.dependencies) var dependencies

    // Convenience accessor
    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }

    var body: some View {
        sheetContent
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch sheet {
        case .settings:
            SettingsView(draftSessionId: sessionId) { server in
                viewModel.showSettings = false
                sheetCoordinator?.activeSheet = nil
                ServerOnboardingLauncher.post(prefill: server)
            }
                .environment(\.dependencies, dependencies)

        case .sessionContext:
            SessionContextSheet(
                sessionId: sessionId,
                serverConnectionId: dependencies.pairedServerStore.activeServer?.id ?? "unpaired",
                contextState: viewModel.contextState,
                currentModelId: viewModel.modelPickerState.displayModelName(current: viewModel.currentModel),
                currentModelInfo: viewModel.modelPickerState.currentModelInfo(current: viewModel.currentModel),
                reasoningLevel: viewModel.inputBarState.reasoningLevel,
                isConnected: dependencies.interactionPolicy.isConnected,
                isAgentActive: viewModel.agentPhase.isActive,
                isCompacting: viewModel.isCompacting,
                isFork: eventStoreManager.sessions.first(where: { $0.id == sessionId })?.isFork == true,
                modelRepository: dependencies.modelRepository,
                sessionRepository: dependencies.sessionRepository,
                workerRepository: dependencies.workerKernelRepository,
                cachedProviderRequestEvents: viewModel.loadedReconstructionEvents.filter {
                    $0.type == SessionEventType.modelProviderRequest.rawValue
                },
                onSelectModel: { model in
                    NotificationCenter.default.post(name: .modelPickerAction, object: model)
                },
                onFork: {
                    try await eventStoreManager.forkSession(sessionId)
                }
            )

        case .compactionDetail(let data):
            CompactionDetailSheet(
                tokensBefore: data.tokensBefore,
                tokensAfter: data.tokensAfter,
                reason: data.reason,
                summary: data.summary,
                preservedTurns: data.preservedTurns,
                summarizedTurns: data.summarizedTurns
            )

        case .thinkingDetail(let data):
            ThinkingDetailSheet(
                state: ThinkingDetailState(
                    thinkingState: viewModel.thinkingState,
                    staticContent: data.content,
                    staticKind: data.kind
                )
            )

        case .toolInvocationDetail(let data):
            toolInvocationDetailSheet(snapshot: data)

        case .toolInvocationGroupDetail(let data):
            toolInvocationGroupDetailSheet(snapshot: data)

        case .providerErrorDetail(let data):
            ProviderErrorDetailSheet(data: data)

        case .localErrorDetail(let data):
            LocalErrorDetailSheet(data: data)

        }
    }

    // MARK: - Sheet Builders

    @ViewBuilder
    private func toolInvocationDetailSheet(snapshot: ToolInvocationData) -> some View {
        let liveData: ToolInvocationData = {
            if let index = MessageFinder.lastIndexOfToolInvocation(id: snapshot.id, in: viewModel.messages),
               case .toolInvocation(let invocation) = viewModel.messages[index].content {
                return invocation
            }
            return snapshot
        }()
        ToolInvocationDetailSheet(data: liveData)
    }

    @ViewBuilder
    private func toolInvocationGroupDetailSheet(snapshot: ToolInvocationGroupData) -> some View {
        let liveInvocations = snapshot.invocations.map { invocation -> ToolInvocationData in
            if let index = MessageFinder.lastIndexOfToolInvocation(id: invocation.id, in: viewModel.messages),
               case .toolInvocation(let liveInvocation) = viewModel.messages[index].content {
                return liveInvocation
            }
            return invocation
        }
        ToolInvocationGroupDetailSheet(data: ToolInvocationGroupData(invocations: liveInvocations))
    }

}
