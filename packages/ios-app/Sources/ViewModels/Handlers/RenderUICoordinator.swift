import Foundation

/// Stateless coordinator for RenderUI event handling.
/// All state flows through the context (ChatViewModel).
@MainActor
final class RenderUICoordinator {

    func handleStarted(_ result: RenderUIStartedPlugin.Result, context: any RenderUIContext) {
        // Update state
        context.renderUIState.startRender(
            canvasId: result.canvasId,
            url: result.url,
            title: result.title
        )

        // Create chip in messages
        let chipData = RenderUIChipData(
            toolCallId: result.toolCallId,
            canvasId: result.canvasId,
            url: result.url,
            title: result.title,
            status: .rendering
        )
        context.addRenderUIChip(chipData)
    }

    func handleReady(_ result: RenderUIReadyPlugin.Result, context: any RenderUIContext) {
        context.renderUIState.markReady(
            canvasId: result.canvasId,
            url: result.url
        )
        context.updateRenderUIChipStatus(canvasId: result.canvasId, status: .ready)
    }

    func handleError(_ result: RenderUIErrorPlugin.Result, context: any RenderUIContext) {
        context.renderUIState.markError(
            canvasId: result.canvasId,
            error: result.error
        )
        context.updateRenderUIChipStatus(canvasId: result.canvasId, status: .error, error: result.error)
    }
}

/// Context protocol for RenderUI coordinator access.
@MainActor
protocol RenderUIContext: AnyObject {
    var renderUIState: RenderUIState { get }
    func addRenderUIChip(_ data: RenderUIChipData)
    func updateRenderUIChipStatus(canvasId: String, status: RenderUIStatus, error: String?)
}

extension RenderUIContext {
    func updateRenderUIChipStatus(canvasId: String, status: RenderUIStatus) {
        updateRenderUIChipStatus(canvasId: canvasId, status: status, error: nil)
    }
}
