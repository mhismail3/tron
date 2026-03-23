import Foundation

// MARK: - RenderUIContext Conformance

/// Extension to make ChatViewModel conform to RenderUIContext.
/// Provides the coordinator with access to state and message mutation.
extension ChatViewModel: RenderUIContext {

    // renderUIState is defined in ChatViewModel.swift

    func addRenderUIChip(_ data: RenderUIChipData) {
        let msg = ChatMessage(
            role: .assistant,
            content: .renderUI(data)
        )
        messages.append(msg)
    }

    func updateRenderUIChipStatus(canvasId: String, status: RenderUIStatus, error: String?) {
        for i in messages.indices.reversed() {
            if case .renderUI(var chipData) = messages[i].content,
               chipData.canvasId == canvasId {
                chipData.status = status
                chipData.errorMessage = error
                messages[i].content = .renderUI(chipData)
                return
            }
        }
    }
}

// MARK: - RenderUIEventHandler Conformance

extension ChatViewModel: RenderUIEventHandler {
    func handleRenderUIStarted(_ result: RenderUIStartedPlugin.Result) {
        renderUICoordinator.handleStarted(result, context: self)
    }

    func handleRenderUIReady(_ result: RenderUIReadyPlugin.Result) {
        renderUICoordinator.handleReady(result, context: self)
    }

    func handleRenderUIError(_ result: RenderUIErrorPlugin.Result) {
        renderUICoordinator.handleError(result, context: self)
    }
}
