import SwiftUI

/// Renders the appropriate sheet content based on ChatSheet enum case.
/// Isolates sheet content from main view body to aid Swift type-checking.
/// This view is used with a single .sheet(item:) modifier in ChatView.
struct ChatSheetContent: View {
    let sheet: ChatSheet
    let viewModel: ChatViewModel
    let agentCockpit: AgentCockpitViewModel
    let sessionId: String
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

        case .agentCockpit:
            AgentCockpitSheet(
                viewModel: agentCockpit,
                repository: viewModel.services.workerLifecycle,
                sessionId: sessionId,
                workspaceId: viewModel.workspaceId.nilIfEmpty,
                connectionState: viewModel.connectionState
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

        case .localErrorDetail(let data):
            LocalErrorDetailSheet(data: data)

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

}
