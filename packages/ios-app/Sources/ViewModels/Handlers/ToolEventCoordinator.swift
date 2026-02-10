import Foundation

/// Coordinates tool event handling (start/end) for ChatViewModel.
///
/// Responsibilities:
/// - Creating tool messages on tool.start
/// - Handling special tools: AskUserQuestion, OpenURL, RenderAppUI
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

    // MARK: - Tool Generating Handling

    /// Handle a tool generating event — emitted when the LLM starts a tool call block,
    /// BEFORE arguments are fully streamed. Creates a spinning chip immediately.
    func handleToolGenerating(
        _ pluginResult: ToolGeneratingPlugin.Result,
        context: ToolEventContext
    ) {
        // Skip tools with custom UI flows or side-effects that require full ToolStartResult
        let kind = ToolKind(toolName: pluginResult.toolName)
        if kind == .askUserQuestion || kind == .renderAppUI || kind == .openURL { return }

        // Finalize any active thinking message before tool chip appears
        context.finalizeThinkingMessageIfNeeded()

        // Skip if chip already exists (catch-up/reconstruction)
        if MessageFinder.hasToolMessage(toolCallId: pluginResult.toolCallId, in: context.messages) { return }

        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        // Create chip with .running status, empty arguments
        let tool = ToolUseData(
            toolName: pluginResult.toolName,
            toolCallId: pluginResult.toolCallId,
            arguments: "",
            status: .running
        )
        let message = ChatMessage(role: .assistant, content: .toolUse(tool))

        context.messages.append(message)
        context.currentToolMessages[message.id] = message
        context.makeToolVisible(pluginResult.toolCallId)
        context.appendToMessageWindow(message)

        // Track tool call for persistence
        let record = ToolCallRecord(
            toolCallId: pluginResult.toolCallId,
            toolName: pluginResult.toolName,
            arguments: ""
        )
        context.currentTurnToolCalls.append(record)

        // Enqueue for UIUpdateQueue ordering
        let toolStartData = UIUpdateQueue.ToolStartData(
            toolCallId: pluginResult.toolCallId,
            toolName: pluginResult.toolName,
            arguments: "",
            timestamp: Date()
        )
        context.enqueueToolStart(toolStartData)
    }

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

        // Finalize any active thinking message before tools begin
        context.finalizeThinkingMessageIfNeeded()

        // CRITICAL: Check if this tool already exists from catch-up or tool_generating.
        // When resuming an in-progress session, catch-up creates tool messages for running/completed tools.
        // tool_generating also pre-creates chips before tool_start arrives.
        // The server then continues streaming those same tools, which would cause duplicates.
        if let existingIndex = MessageFinder.lastIndexOfToolUse(toolCallId: pluginResult.toolCallId, in: context.messages) {
            context.logInfo("Updating existing tool.start for \(pluginResult.toolName) (toolCallId: \(pluginResult.toolCallId)) with arguments")
            // Still make the tool visible (in case it wasn't)
            context.makeToolVisible(pluginResult.toolCallId)

            // Update the existing chip with full arguments from tool_start
            if case .toolUse(var tool) = context.messages[existingIndex].content {
                tool.arguments = pluginResult.formattedArguments
                context.messages[existingIndex].content = .toolUse(tool)
                context.currentToolMessages[context.messages[existingIndex].id] = context.messages[existingIndex]
                context.updateInMessageWindow(context.messages[existingIndex])
            }

            // Update tracked tool call arguments
            if let idx = context.currentTurnToolCalls.firstIndex(where: { $0.toolCallId == pluginResult.toolCallId }) {
                context.currentTurnToolCalls[idx].arguments = pluginResult.formattedArguments
            }

            // Still handle browser tool detection for pre-existing chips
            if result.isBrowserTool {
                let shouldStartStreaming = context.updateBrowserStatusIfNeeded()
                if shouldStartStreaming {
                    context.startBrowserStreamIfNeeded()
                }
            }
            return
        }

        // Finalize any current streaming text before tool starts
        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        // Handle AskUserQuestion specially
        if result.isAskUserQuestion {
            handleAskUserQuestionToolStart(pluginResult, params: result.askUserQuestionParams, context: context)
            return
        }

        // Handle OpenURL - opens Safari but also displays as regular tool
        if result.isOpenURL {
            handleOpenURLToolStart(url: result.openURL, context: context)
            // Don't return - still display as regular tool use
        }

        // Create the tool message
        var message = ChatMessage(role: .assistant, content: .toolUse(result.tool))

        // Special handling for RenderAppUI
        if ToolKind(toolName: pluginResult.toolName) == .renderAppUI {
            let handled = handleRenderAppUIToolStart(pluginResult, message: &message, context: context)
            if handled {
                // Existing chip was updated, don't create new message
                return
            }
        } else if let pendingRender = context.renderAppUIChipTracker.consumePendingRenderStart(toolCallId: pluginResult.toolCallId) {
            // Handle pending UI render (race condition: chunk arrived before tool start)
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
            let shouldStartStreaming = context.updateBrowserStatusIfNeeded()
            if shouldStartStreaming {
                context.startBrowserStreamIfNeeded()
            }
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

        // Finalize the current thinking message before starting a new block
        context.finalizeThinkingMessageIfNeeded()

        // Reset thinking state after tool completion
        // Any subsequent thinking deltas should start a new thinking block
        context.resetThinkingForNewBlock()

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
                if ToolKind(toolName: tool.toolName) == .browseTheWeb {
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
            durationMs: result.durationMs,
            details: pluginResult.rawDetails
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

    /// Handle OpenURL tool start - opens Safari in-app browser
    private func handleOpenURLToolStart(url: URL?, context: ToolEventContext) {
        context.logInfo("OpenURL tool detected")

        guard let url = url else {
            context.logError("Failed to parse OpenURL URL from arguments")
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
           let messageId = chipState.messageId,
           let index = MessageFinder.indexById(messageId, in: context.messages),
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
