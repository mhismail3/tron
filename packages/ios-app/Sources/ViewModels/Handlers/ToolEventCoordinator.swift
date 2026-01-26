import Foundation

/// Coordinates tool event handling (start/end) for ChatViewModel.
///
/// Responsibilities:
/// - Creating tool messages on tool.start
/// - Handling special tools: AskUserQuestion, OpenBrowser, RenderAppUI
/// - Managing RenderAppUI chip race conditions (chunk vs tool_start order)
/// - Tracking tool calls for the current turn
/// - Enqueuing tool events for ordered UI processing
///
/// This coordinator extracts the complex tool handling logic from ChatViewModel+Events.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class ToolEventCoordinator {

    // MARK: - Initialization

    init() {}

    // MARK: - Tool Start Handling

    /// Handle a tool start event.
    ///
    /// - Parameters:
    ///   - pluginResult: The plugin result with tool start data
    ///   - result: The processed result from ChatEventHandler
    ///   - context: The context providing access to state and dependencies
    func handleToolStart(
        _ pluginResult: ToolStartPlugin.Result,
        result: ToolStartResult,
        context: ToolEventContext
    ) {
        context.logDebug("Tool args: \(pluginResult.formattedArguments.prefix(200))")

        // Finalize any current streaming text before tool starts
        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        // Handle AskUserQuestion specially
        if result.isAskUserQuestion {
            handleAskUserQuestionToolStart(pluginResult, params: result.askUserQuestionParams, context: context)
            return
        }

        // Handle OpenBrowser - opens Safari but also displays as regular tool
        if result.isOpenBrowser {
            handleOpenBrowserToolStart(url: result.openBrowserURL, context: context)
            // Don't return - still display as regular tool use
        }

        // Create the tool message
        var message = ChatMessage(role: .assistant, content: .toolUse(result.tool))

        // Special handling for RenderAppUI
        if pluginResult.toolName.lowercased() == "renderappui" {
            let handled = handleRenderAppUIToolStart(pluginResult, message: &message, context: context)
            if handled {
                // Existing chip was updated, don't create new message
                return
            }
        } else if let pendingRender = context.renderAppUIChipTracker.consumePendingRenderStart(toolCallId: pluginResult.toolCallId) {
            // Handle pending UI render start (legacy path) - via tracker
            let chipData = RenderAppUIChipData(
                toolCallId: pluginResult.toolCallId,
                canvasId: pendingRender.canvasId,
                title: pendingRender.title,
                status: .rendering,
                errorMessage: nil
            )
            message.content = .renderAppUI(chipData)

            // Track in tracker (single source of truth)
            context.renderAppUIChipTracker.createChipFromToolStart(
                canvasId: pendingRender.canvasId,
                messageId: message.id,
                toolCallId: pluginResult.toolCallId,
                title: pendingRender.title
            )
            context.logDebug("Applied pending UI render start to new tool message: \(pendingRender.canvasId)")
        }

        // Append message to chat
        context.messages.append(message)
        context.currentToolMessages[message.id] = message

        // Make tool immediately visible for rendering
        context.makeToolVisible(pluginResult.toolCallId)

        // Sync to MessageWindowManager for virtual scrolling
        context.appendToMessageWindow(message)

        // Track tool call for persistence
        let record = ToolCallRecord(
            toolCallId: pluginResult.toolCallId,
            toolName: pluginResult.toolName,
            arguments: pluginResult.formattedArguments
        )
        context.currentTurnToolCalls.append(record)

        // Update browser status for browser tools
        if result.isBrowserTool {
            context.logInfo("Browser tool detected")
            context.updateBrowserStatusIfNeeded()
        }

        // Enqueue tool start for ordered processing and staggered animation
        let toolStartData = UIUpdateQueue.ToolStartData(
            toolCallId: pluginResult.toolCallId,
            toolName: pluginResult.toolName,
            arguments: pluginResult.formattedArguments,
            timestamp: Date()
        )
        context.enqueueToolStart(toolStartData)
    }

    // MARK: - Tool End Handling

    /// Handle a tool end event.
    ///
    /// - Parameters:
    ///   - pluginResult: The plugin result with tool end data
    ///   - result: The processed result from ChatEventHandler
    ///   - context: The context providing access to state and dependencies
    func handleToolEnd(
        _ pluginResult: ToolEndPlugin.Result,
        result: ToolEndResult,
        context: ToolEventContext
    ) {
        context.logInfo("Tool ended: \(result.toolCallId) status=\(result.status) duration=\(result.durationMs ?? 0)ms")
        context.logDebug("Tool result: \(result.result.prefix(300))")

        // Check if this is an AskUserQuestion tool end
        if let index = MessageFinder.lastIndexOfAskUserQuestion(toolCallId: result.toolCallId, in: context.messages) {
            if case .askUserQuestion(let data) = context.messages[index].content {
                // In async mode, tool.end means questions are ready for user
                // Status is already .pending, now auto-open the sheet
                context.logInfo("AskUserQuestion tool.end - opening sheet for user input")
                context.openAskUserQuestionSheet(for: data)
            }
            return
        }

        // Check if this is a browser tool result with screenshot data
        if let index = MessageFinder.lastIndexOfToolUse(toolCallId: result.toolCallId, in: context.messages) {
            if case .toolUse(let tool) = context.messages[index].content {
                if tool.toolName.lowercased().contains("browser") {
                    // Browser screenshot extraction is handled by ChatViewModel
                    // (requires access to BrowserScreenshotService and browserState.browserFrame)
                    // We just log here that it would be extracted
                    context.logDebug("Browser tool result - screenshot extraction handled by context")
                }
            }
        }

        // Update tracked tool call with result
        if let idx = context.currentTurnToolCalls.firstIndex(where: { $0.toolCallId == result.toolCallId }) {
            context.currentTurnToolCalls[idx].result = result.result
            context.currentTurnToolCalls[idx].isError = (result.status == .error)
        }

        // Enqueue tool end for ordered processing
        let toolEndData = UIUpdateQueue.ToolEndData(
            toolCallId: result.toolCallId,
            success: (result.status == .success),
            result: result.result,
            durationMs: result.durationMs
        )
        context.enqueueToolEnd(toolEndData)
    }

    // MARK: - Private Helpers

    /// Handle AskUserQuestion tool start - creates special message
    private func handleAskUserQuestionToolStart(
        _ pluginResult: ToolStartPlugin.Result,
        params: AskUserQuestionParams?,
        context: ToolEventContext
    ) {
        context.logInfo("AskUserQuestion tool detected")

        // Mark that AskUserQuestion was called in this turn
        // This suppresses any subsequent text deltas (question should be final entry)
        context.askUserQuestionCalledInTurn = true

        // Use pre-parsed params, fall back to regular tool display if parsing failed
        guard let params = params else {
            context.logError("Failed to parse AskUserQuestion params: \(pluginResult.formattedArguments.prefix(500))")
            // Fall back to regular tool display
            let tool = ToolUseData(
                toolName: pluginResult.toolName,
                toolCallId: pluginResult.toolCallId,
                arguments: pluginResult.formattedArguments,
                status: .running
            )
            let message = ChatMessage(role: .assistant, content: .toolUse(tool))
            context.messages.append(message)
            context.makeToolVisible(pluginResult.toolCallId)
            return
        }

        // Create AskUserQuestion tool data with pending status
        let toolData = AskUserQuestionToolData(
            toolCallId: pluginResult.toolCallId,
            params: params,
            answers: [:],
            status: .pending,
            result: nil
        )

        // Create message with AskUserQuestion content
        let message = ChatMessage(role: .assistant, content: .askUserQuestion(toolData))
        context.messages.append(message)

        // Track tool call for persistence
        let record = ToolCallRecord(
            toolCallId: pluginResult.toolCallId,
            toolName: pluginResult.toolName,
            arguments: pluginResult.formattedArguments
        )
        context.currentTurnToolCalls.append(record)

        // Note: Sheet auto-opens on tool.end, not tool.start (async mode)
    }

    /// Handle OpenBrowser tool start - opens Safari in-app browser
    private func handleOpenBrowserToolStart(url: URL?, context: ToolEventContext) {
        context.logInfo("OpenBrowser tool detected")

        guard let url = url else {
            context.logError("Failed to parse OpenBrowser URL from arguments")
            return
        }

        context.logInfo("Opening Safari with URL: \(url.absoluteString)")
        context.safariURL = url
    }

    /// Handle RenderAppUI tool start - manages chip creation/update.
    ///
    /// - Returns: `true` if an existing chip was updated (caller should not create new message),
    ///            `false` if a new chip was created in the message (caller should add the message)
    private func handleRenderAppUIToolStart(
        _ pluginResult: ToolStartPlugin.Result,
        message: inout ChatMessage,
        context: ToolEventContext
    ) -> Bool {
        // Parse arguments to get canvasId
        guard let argsData = pluginResult.formattedArguments.data(using: .utf8),
              let argsJson = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
              let canvasId = argsJson["canvasId"] as? String else {
            return false
        }

        // Check if chip already exists from ui_render_chunk (via tracker)
        if let chipState = context.renderAppUIChipTracker.getChip(canvasId: canvasId),
           let index = MessageFinder.indexById(chipState.messageId, in: context.messages),
           case .renderAppUI(var chipData) = context.messages[index].content {
            // Chip already exists - update toolCallId to real one
            let oldToolCallId = chipData.toolCallId
            chipData.toolCallId = pluginResult.toolCallId
            context.messages[index].content = .renderAppUI(chipData)

            // Update tracker atomically
            context.renderAppUIChipTracker.updateToolCallId(canvasId: canvasId, realToolCallId: pluginResult.toolCallId)

            // Update currentToolMessages with correct ID
            context.currentToolMessages[context.messages[index].id] = context.messages[index]

            // Track tool call for persistence
            let record = ToolCallRecord(
                toolCallId: pluginResult.toolCallId,
                toolName: pluginResult.toolName,
                arguments: pluginResult.formattedArguments
            )
            context.currentTurnToolCalls.append(record)

            context.logInfo("Updated existing RenderAppUI chip toolCallId: \(canvasId), \(oldToolCallId) → \(pluginResult.toolCallId)")

            // Signal to caller that existing chip was updated, don't create new message
            return true
        }

        // No existing chip - create one now
        let title = argsJson["title"] as? String
        let chipData = RenderAppUIChipData(
            toolCallId: pluginResult.toolCallId,
            canvasId: canvasId,
            title: title,
            status: .rendering,
            errorMessage: nil
        )
        message.content = .renderAppUI(chipData)

        // Track in tracker (single source of truth)
        context.renderAppUIChipTracker.createChipFromToolStart(
            canvasId: canvasId,
            messageId: message.id,
            toolCallId: pluginResult.toolCallId,
            title: title
        )
        context.logDebug("Created RenderAppUI chip from tool_start: \(canvasId)")

        // Signal to caller that new message should be added
        return false
    }
}
