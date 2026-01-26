import Foundation

/// Coordinates UI canvas rendering event handling for ChatViewModel.
///
/// Responsibilities:
/// - Handling ui.render.start/chunk/complete/error/retry events
/// - Managing RenderAppUI chip creation and status updates
/// - Coordinating with UICanvasState for canvas lifecycle
/// - Handling the race condition where chunk arrives before tool_start
///
/// This coordinator extracts the UI canvas rendering logic from ChatViewModel+Events.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class UICanvasCoordinator {

    // MARK: - Initialization

    init() {}

    // MARK: - UI Render Start

    /// Handle a UI render start event.
    ///
    /// - Parameters:
    ///   - event: The UI render start event from the server
    ///   - context: The context providing access to state and dependencies
    func handleUIRenderStart(_ event: UIRenderStartEvent, context: UICanvasContext) {
        context.logInfo("UI render started: canvasId=\(event.canvasId), title=\(event.title ?? "none")")

        // Find the RenderAppUI message by toolCallId
        // Check if already converted to chip (from handleToolStart) or still a toolUse
        if let index = MessageFinder.lastIndexOfRenderAppUI(toolCallId: event.toolCallId, in: context.messages) {
            // Update or convert to chip with rendering status
            let chipData = RenderAppUIChipData(
                toolCallId: event.toolCallId,
                canvasId: event.canvasId,
                title: event.title,
                status: .rendering,
                errorMessage: nil
            )
            context.messages[index].content = .renderAppUI(chipData)

            // Track in tracker (creates or updates)
            if context.renderAppUIChipTracker.hasChip(canvasId: event.canvasId) {
                context.renderAppUIChipTracker.updateToolCallId(canvasId: event.canvasId, realToolCallId: event.toolCallId)
            } else {
                context.renderAppUIChipTracker.createChipFromToolStart(
                    canvasId: event.canvasId,
                    messageId: context.messages[index].id,
                    toolCallId: event.toolCallId,
                    title: event.title
                )
            }
            context.logDebug("Updated/converted RenderAppUI to chip: \(event.canvasId)")
        } else {
            // Tool message doesn't exist yet (ui.render.start arrived before tool.start via streaming)
            // Store the event in tracker for processing when tool.start arrives
            context.renderAppUIChipTracker.storePendingRenderStart(event)
            context.logDebug("Stored pending UI render start for toolCallId: \(event.toolCallId)")
        }

        // Start rendering in canvas state (this will show the sheet)
        context.uiCanvasState.startRender(
            canvasId: event.canvasId,
            title: event.title,
            toolCallId: event.toolCallId
        )
    }

    // MARK: - UI Render Chunk

    /// Handle a UI render chunk event.
    ///
    /// - Parameters:
    ///   - event: The UI render chunk event from the server
    ///   - context: The context providing access to state and dependencies
    func handleUIRenderChunk(_ event: UIRenderChunkEvent, context: UICanvasContext) {
        context.logVerbose("UI render chunk: canvasId=\(event.canvasId), +\(event.chunk.count) chars")

        // CRITICAL FIX: ui_render_chunk arrives BEFORE tool_start in streaming mode.
        // Create the chip on FIRST chunk so user sees "Rendering..." immediately.
        // Use tracker to check if chip exists (single source of truth)
        if !context.renderAppUIChipTracker.hasChip(canvasId: event.canvasId) {
            // First chunk for this canvasId - create the rendering chip
            // Try to extract title from accumulated JSON
            let title = extractTitleFromAccumulated(event.accumulated)

            let message = ChatMessage(role: .assistant, content: .renderAppUI(RenderAppUIChipData(
                toolCallId: "pending_\(event.canvasId)", // Placeholder
                canvasId: event.canvasId,
                title: title,
                status: .rendering,
                errorMessage: nil
            )))
            context.messages.append(message)

            // Track in tracker (single source of truth, returns placeholder toolCallId)
            let placeholderToolCallId = context.renderAppUIChipTracker.createChipFromChunk(
                canvasId: event.canvasId,
                messageId: message.id,
                title: title
            )

            // Make chip immediately visible
            context.animationCoordinator.makeToolVisible(placeholderToolCallId)

            // Sync to MessageWindowManager
            context.messageWindowManager.appendMessage(message)

            context.logInfo("Created RenderAppUI chip from first chunk: \(event.canvasId), title=\(title ?? "nil")")

            // Also start canvas render state (shows sheet)
            context.uiCanvasState.startRender(
                canvasId: event.canvasId,
                title: title,
                toolCallId: placeholderToolCallId
            )
        }

        // FIX: Ensure canvas exists even if chip was created by tool_start
        // This handles the race condition where tool_start arrives before ui_render_chunk.
        // tool_start creates the chip but doesn't call startRender(), so the canvas
        // won't exist when updateRender() is called. This check ensures we create
        // the canvas state before attempting to update it.
        if !context.uiCanvasState.hasCanvas(event.canvasId) {
            let title = extractTitleFromAccumulated(event.accumulated)
            let toolCallId = getToolCallIdForCanvas(event.canvasId, context: context) ?? "pending_\(event.canvasId)"
            context.uiCanvasState.startRender(
                canvasId: event.canvasId,
                title: title,
                toolCallId: toolCallId
            )
            context.logInfo("Created canvas state for existing chip: \(event.canvasId)")
        }

        // Update the canvas with the new chunk
        context.uiCanvasState.updateRender(
            canvasId: event.canvasId,
            chunk: event.chunk,
            accumulated: event.accumulated
        )
    }

    // MARK: - UI Render Complete

    /// Handle a UI render complete event.
    ///
    /// - Parameters:
    ///   - event: The UI render complete event from the server
    ///   - context: The context providing access to state and dependencies
    func handleUIRenderComplete(_ event: UIRenderCompleteEvent, context: UICanvasContext) {
        context.logInfo("UI render complete: canvasId=\(event.canvasId)")

        // Update chip status to complete (use tracker as single source of truth)
        if let chipState = context.renderAppUIChipTracker.getChip(canvasId: event.canvasId),
           let index = MessageFinder.indexById(chipState.messageId, in: context.messages),
           case .renderAppUI(var chipData) = context.messages[index].content {
            chipData.status = .complete
            chipData.errorMessage = nil
            context.messages[index].content = .renderAppUI(chipData)
            context.logDebug("Updated RenderAppUI chip to complete: \(event.canvasId)")
        }

        // Convert [String: AnyCodable] to [String: Any] for parsing
        guard let uiDict = event.ui else {
            context.logError("No UI dictionary for canvas \(event.canvasId)")
            return
        }

        let rawDict: [String: Any] = uiDict.mapValues { $0.value }

        // Parse the raw UI dictionary into UICanvasComponent
        guard let component = UICanvasParser.parse(rawDict) else {
            context.logError("Failed to parse UI component for canvas \(event.canvasId)")
            return
        }

        // Complete the render with the final UI tree
        context.uiCanvasState.completeRender(
            canvasId: event.canvasId,
            ui: component,
            state: event.state
        )
    }

    // MARK: - UI Render Error

    /// Handle a UI render error event.
    ///
    /// - Parameters:
    ///   - event: The UI render error event from the server
    ///   - context: The context providing access to state and dependencies
    func handleUIRenderError(_ event: UIRenderErrorEvent, context: UICanvasContext) {
        context.logWarning("UI render error: canvasId=\(event.canvasId), error=\(event.error)")

        // Update chip status to error (use tracker as single source of truth)
        if let chipState = context.renderAppUIChipTracker.getChip(canvasId: event.canvasId),
           let index = MessageFinder.indexById(chipState.messageId, in: context.messages),
           case .renderAppUI(var chipData) = context.messages[index].content {
            chipData.status = .error
            chipData.errorMessage = event.error
            context.messages[index].content = .renderAppUI(chipData)
            context.logDebug("Updated RenderAppUI chip to error: \(event.canvasId)")
        }

        // Mark the canvas as errored - this will update the UI to show the error
        // instead of leaving it stuck in "Rendering..." state
        context.uiCanvasState.errorRender(canvasId: event.canvasId, error: event.error)
    }

    // MARK: - UI Render Retry

    /// Handle a UI render retry event.
    ///
    /// - Parameters:
    ///   - event: The UI render retry event from the server
    ///   - context: The context providing access to state and dependencies
    func handleUIRenderRetry(_ event: UIRenderRetryEvent, context: UICanvasContext) {
        context.logInfo("UI render retry: canvasId=\(event.canvasId), attempt=\(event.attempt)")

        // Validation failure means error - chip shows error state (not tappable)
        // The agent will create a NEW chip with the retry, so this one stays as error
        // Use tracker as single source of truth
        if let chipState = context.renderAppUIChipTracker.getChip(canvasId: event.canvasId),
           let index = MessageFinder.indexById(chipState.messageId, in: context.messages),
           case .renderAppUI(var chipData) = context.messages[index].content {
            chipData.status = .error
            chipData.errorMessage = "Error generating"
            context.messages[index].content = .renderAppUI(chipData)
            context.logDebug("Updated RenderAppUI chip to error (validation failed): \(event.canvasId)")
        }

        // Update canvas to show retry status - keeps the sheet open so user sees progress
        // The agent will automatically retry with a corrected UI definition
        context.uiCanvasState.setRetrying(
            canvasId: event.canvasId,
            attempt: event.attempt,
            errors: event.errors
        )
    }

    // MARK: - Private Helpers

    /// Extract title from accumulated RenderAppUI JSON arguments
    private func extractTitleFromAccumulated(_ accumulated: String) -> String? {
        // Try to extract "title" field: {"canvasId": "...", "title": "...", ...}
        // Use NSRegularExpression for compatibility
        let pattern = #""title"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: accumulated, options: [], range: NSRange(accumulated.startIndex..., in: accumulated)),
              let range = Range(match.range(at: 1), in: accumulated) else {
            return nil
        }
        return String(accumulated[range])
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Get the toolCallId for an existing RenderAppUI chip
    private func getToolCallIdForCanvas(_ canvasId: String, context: UICanvasContext) -> String? {
        // Use tracker as single source of truth
        guard let chipState = context.renderAppUIChipTracker.getChip(canvasId: canvasId),
              let message = context.messages.first(where: { $0.id == chipState.messageId }),
              case .renderAppUI(let data) = message.content else {
            return nil
        }
        return data.toolCallId
    }
}
