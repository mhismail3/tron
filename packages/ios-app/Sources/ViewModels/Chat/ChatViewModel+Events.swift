import Foundation
import UIKit
import SwiftUI

// MARK: - Event Handlers

extension ChatViewModel {

    func handleTextDelta(_ delta: String) {
        // Skip text if AskUserQuestion was called in this turn
        // (AskUserQuestion should be the final visible entry when called)
        guard !askUserQuestionState.calledInTurn else {
            logger.verbose("Skipping text delta - AskUserQuestion was called in this turn", category: .events)
            return
        }

        // Delegate to StreamingManager for batched processing
        let accepted = streamingManager.handleTextDelta(delta)

        if !accepted {
            logger.warning("Streaming text limit reached, dropping delta", category: .events)
            return
        }

        // Track as first text message of this turn if not already set
        // (StreamingManager is now single source of truth for streamingMessageId)
        if let id = streamingManager.streamingMessageId, firstTextMessageIdForTurn == nil {
            firstTextMessageIdForTurn = id
            logger.debug("Tracked first text message for turn: \(id)", category: .events)
        }

        logger.verbose("Text delta received: +\(delta.count) chars, total: \(streamingManager.streamingText.count)", category: .events)
    }

    func handleThinkingDelta(_ delta: String) {
        // Process through handler (accumulates thinking text)
        let result = eventHandler.handleThinkingDelta(delta)

        // Create thinking message on first delta (so it appears BEFORE the text response)
        if thinkingMessageId == nil {
            let thinkingMessage = ChatMessage.thinking(result.thinkingText, isStreaming: true)
            messages.append(thinkingMessage)
            thinkingMessageId = thinkingMessage.id
            messageWindowManager.appendMessage(thinkingMessage)
            logger.debug("Created thinking message: \(thinkingMessage.id)", category: .events)
        } else if let id = thinkingMessageId,
                  let index = MessageFinder.indexById(id, in: messages) {
            // Update existing thinking message with accumulated content
            messages[index].content = .thinking(visible: result.thinkingText, isExpanded: false, isStreaming: true)
        }

        // Also route to ThinkingState for sheet/history functionality
        thinkingState.handleThinkingDelta(delta)

        logger.verbose("Thinking delta: +\(delta.count) chars, total: \(result.thinkingText.count)", category: .events)
    }

    func handleToolStart(_ pluginResult: ToolStartPlugin.Result) {
        // Process through handler (classifies tool type, parses params)
        let result = eventHandler.handleToolStart(pluginResult, context: self)

        // Delegate to coordinator for all tool start handling
        toolEventCoordinator.handleToolStart(pluginResult, result: result, context: self)
    }

    func handleToolEnd(_ pluginResult: ToolEndPlugin.Result) {
        // Process through handler (extracts status and result)
        let result = eventHandler.handleToolEnd(pluginResult)

        // Check if this is a browser tool result with screenshot data
        // (Extract screenshot before coordinator - needs access to BrowserScreenshotService)
        if let index = MessageFinder.lastIndexOfToolUse(toolCallId: result.toolCallId, in: messages) {
            if case .toolUse(let tool) = messages[index].content {
                if tool.toolName.lowercased() == "browsetheweb" {
                    // Pass plugin result for screenshot extraction (needs result.details)
                    extractAndDisplayBrowserScreenshot(from: pluginResult)
                }
            }
        }

        // Delegate to coordinator for all tool end handling
        toolEventCoordinator.handleToolEnd(pluginResult, result: result, context: self)
    }

    /// Extract screenshot from browser tool result and display it.
    /// Uses BrowserScreenshotService for extraction, handling result details and text patterns.
    private func extractAndDisplayBrowserScreenshot(from pluginResult: ToolEndPlugin.Result) {
        guard let extractionResult = BrowserScreenshotService.extractScreenshot(from: pluginResult) else {
            return
        }

        logger.info("Browser screenshot from \(extractionResult.source.rawValue) (\(extractionResult.image.size.width)x\(extractionResult.image.size.height))", category: .events)
        browserState.browserFrame = extractionResult.image

        // Only auto-show if user hasn't manually dismissed this turn
        if !browserState.userDismissedBrowserThisTurn && !browserState.showBrowserWindow {
            browserState.showBrowserWindow = true
        }
    }

    func handleTurnStart(_ pluginResult: TurnStartPlugin.Result) {
        // Process through handler (resets handler streaming state)
        let result = eventHandler.handleTurnStart(pluginResult)

        // Delegate to coordinator for all turn start handling
        turnLifecycleCoordinator.handleTurnStart(pluginResult, result: result, context: self)
    }

    func handleTurnEnd(_ pluginResult: TurnEndPlugin.Result) {
        // Process through handler (extracts normalized values)
        let result = eventHandler.handleTurnEnd(pluginResult)

        // Delegate to coordinator for all turn end handling
        turnLifecycleCoordinator.handleTurnEnd(pluginResult, result: result, context: self)
    }

    func handleComplete() {
        // Capture streaming text before finalization clears it
        let finalStreamingText = streamingManager.streamingText

        // Process through handler (resets handler state)
        _ = eventHandler.handleComplete()

        // Delegate to coordinator for all completion handling
        turnLifecycleCoordinator.handleComplete(streamingText: finalStreamingText, context: self)
    }

    func handleCompaction(_ pluginResult: CompactionPlugin.Result) {
        // Process event through handler
        let result = eventHandler.handleCompaction(pluginResult)
        logger.info("Context compacted: \(result.tokensBefore) -> \(result.tokensAfter) tokens (saved \(result.tokensSaved), reason: \(result.reason))", category: .events)

        // Finalize any current streaming before adding notification
        flushPendingTextUpdates()
        finalizeStreamingMessage()

        // Update context tracking - the new context size is tokensAfter
        contextState.lastTurnInputTokens = result.tokensAfter
        logger.debug("Updated lastTurnInputTokens to \(result.tokensAfter) after compaction", category: .events)

        // Add compaction notification pill to chat
        let compactionMessage = ChatMessage.compaction(
            tokensBefore: result.tokensBefore,
            tokensAfter: result.tokensAfter,
            reason: result.reason,
            summary: result.summary
        )
        messages.append(compactionMessage)

        // Refresh context from server to ensure context limit is also current
        Task {
            await refreshContextFromServer()
        }
    }

    func handleContextCleared(_ pluginResult: ContextClearedPlugin.Result) {
        // Process event through handler
        let result = eventHandler.handleContextCleared(pluginResult)
        logger.info("Context cleared: \(result.tokensBefore) -> \(result.tokensAfter) tokens (freed \(result.tokensFreed))", category: .events)

        // Finalize any current streaming before adding notification
        flushPendingTextUpdates()
        finalizeStreamingMessage()

        // Update context tracking - the new context size is tokensAfter
        contextState.lastTurnInputTokens = result.tokensAfter
        logger.debug("Updated lastTurnInputTokens to \(result.tokensAfter) after context clear", category: .events)

        // Add context cleared notification pill to chat
        let clearedMessage = ChatMessage.contextCleared(
            tokensBefore: result.tokensBefore,
            tokensAfter: result.tokensAfter
        )
        messages.append(clearedMessage)

        // Refresh context from server to ensure context limit is also current
        Task {
            await refreshContextFromServer()
        }
    }

    func handleMessageDeleted(_ pluginResult: MessageDeletedPlugin.Result) {
        // Process event through handler
        let result = eventHandler.handleMessageDeleted(pluginResult)
        logger.info("Message deleted: targetType=\(result.targetType), eventId=\(result.targetEventId)", category: .events)

        // Add message deleted notification pill to chat
        let deletedMessage = ChatMessage.messageDeleted(targetType: result.targetType)
        messages.append(deletedMessage)
    }

    func handleSkillRemoved(_ pluginResult: SkillRemovedPlugin.Result) {
        // Process event through handler
        let result = eventHandler.handleSkillRemoved(pluginResult)
        logger.info("Skill removed: \(result.skillName)", category: .events)

        // Add skill removed notification pill to chat
        let skillRemovedMessage = ChatMessage.skillRemoved(skillName: result.skillName)
        messages.append(skillRemovedMessage)

        // Refresh context from server - skill removal changes context size
        // Server is authoritative source for accurate token counts after context changes
        Task {
            await refreshContextFromServer()
        }
    }

    func handlePlanModeEntered(_ pluginResult: PlanModeEnteredPlugin.Result) {
        // Process event through handler
        let result = eventHandler.handlePlanModeEntered(pluginResult)
        logger.info("Plan mode entered: skill=\(result.skillName), blocked=\(result.blockedTools.joined(separator: ", "))", category: .events)

        // Update state and add notification to chat
        enterPlanMode(skillName: result.skillName, blockedTools: result.blockedTools)
    }

    func handlePlanModeExited(_ pluginResult: PlanModeExitedPlugin.Result) {
        // Process event through handler
        let result = eventHandler.handlePlanModeExited(pluginResult)
        logger.info("Plan mode exited: reason=\(result.reason), planPath=\(result.planPath ?? "none")", category: .events)

        // Update state and add notification to chat
        exitPlanMode(reason: result.reason, planPath: result.planPath)
    }

    /// Handle errors from the agent streaming (shows error in chat)
    func handleAgentError(_ message: String) {
        // Process through handler (resets handler state)
        let result = eventHandler.handleAgentError(message)
        logger.error("Agent error: \(result.message)", category: .events)

        // Flush and reset all manager states on error
        uiUpdateQueue.flush()
        uiUpdateQueue.reset()
        animationCoordinator.resetToolState()
        streamingManager.reset()

        isProcessing = false
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
        eventStoreManager?.updateSessionDashboardInfo(
            sessionId: sessionId,
            lastAssistantResponse: "Error: \(String(result.message.prefix(100)))"
        )
        finalizeStreamingMessage()
        messages.append(.error(result.message))

        // NOTE: Do NOT clear ThinkingState here - thinking caption should persist
        // so user can see what was happening before the error (cleared on next turn)

        // Close browser session on error
        closeBrowserSession()
    }

    /// Sync session events from server after turn completes
    func syncSessionEventsFromServer() async {
        guard let manager = eventStoreManager else {
            logger.warning("No EventStoreManager available for sync", category: .events)
            return
        }

        do {
            try await manager.syncSessionEvents(sessionId: sessionId)
            logger.info("Synced session events from server for session \(sessionId)", category: .events)
        } catch {
            logger.error("Failed to sync session events: \(error.localizedDescription)", category: .events)
        }
    }

    // MARK: - UI Canvas Event Handlers

    func handleUIRenderStart(_ pluginResult: UIRenderStartPlugin.Result) {
        // Delegate to coordinator for all UI render start handling
        uiCanvasCoordinator.handleUIRenderStart(pluginResult, context: self)
    }

    func handleUIRenderChunk(_ pluginResult: UIRenderChunkPlugin.Result) {
        // Delegate to coordinator for all UI render chunk handling
        uiCanvasCoordinator.handleUIRenderChunk(pluginResult, context: self)
    }

    func handleUIRenderComplete(_ pluginResult: UIRenderCompletePlugin.Result) {
        // Delegate to coordinator for all UI render complete handling
        uiCanvasCoordinator.handleUIRenderComplete(pluginResult, context: self)
    }

    func handleUIRenderError(_ pluginResult: UIRenderErrorPlugin.Result) {
        // Delegate to coordinator for all UI render error handling
        uiCanvasCoordinator.handleUIRenderError(pluginResult, context: self)
    }

    func handleUIRenderRetry(_ pluginResult: UIRenderRetryPlugin.Result) {
        // Delegate to coordinator for all UI render retry handling
        uiCanvasCoordinator.handleUIRenderRetry(pluginResult, context: self)
    }

    // MARK: - Todo Event Handlers

    func handleTodosUpdated(_ pluginResult: TodosUpdatedPlugin.Result) {
        // Process through handler (extracts todos)
        let result = eventHandler.handleTodosUpdated(pluginResult)
        logger.debug("Todos updated: count=\(result.todos.count), restoredCount=\(result.restoredCount)", category: .events)

        // Update todo state directly from plugin result
        todoState.updateTodos(pluginResult.todos)
    }

    // MARK: - Plugin Result Handlers
    // These handlers accept plugin Result types directly, bridging the plugin system
    // to the existing event handler infrastructure.


    func handleAgentTurn(_ result: AgentTurnPlugin.Result) {
        logger.info("Agent turn received: \(result.messages.count) messages, \(result.toolUses.count) tool uses, \(result.toolResults.count) tool results", category: .events)

        guard let manager = eventStoreManager else {
            logger.warning("No EventStoreManager to cache agent turn content", category: .events)
            return
        }

        // Convert AgentTurnPlugin messages to cacheable format
        var turnMessages: [[String: Any]] = []
        for msg in result.messages {
            var messageDict: [String: Any] = ["role": msg.role]

            switch msg.content {
            case .text(let text):
                messageDict["content"] = text
            case .blocks(let blocks):
                var contentBlocks: [[String: Any]] = []
                for block in blocks {
                    switch block {
                    case .text(let text):
                        contentBlocks.append(["type": "text", "text": text])
                    case .toolUse(let id, let name, let input):
                        var inputDict: [String: Any] = [:]
                        for (key, value) in input {
                            inputDict[key] = value.value
                        }
                        contentBlocks.append([
                            "type": "tool_use",
                            "id": id,
                            "name": name,
                            "input": inputDict
                        ])
                    case .toolResult(let toolUseId, let content, let isError):
                        contentBlocks.append([
                            "type": "tool_result",
                            "tool_use_id": toolUseId,
                            "content": content,
                            "is_error": isError
                        ])
                    case .thinking(let text):
                        contentBlocks.append(["type": "thinking", "thinking": text])
                    case .unknown:
                        break
                    }
                }
                messageDict["content"] = contentBlocks
            }
            turnMessages.append(messageDict)
        }

        // Cache the turn content for merging with server events
        manager.turnContentCache.store(
            sessionId: sessionId,
            turnNumber: result.turnNumber,
            messages: turnMessages
        )

        // Trigger sync AFTER caching content
        logger.info("Triggering sync after caching agent turn content", category: .events)
        Task {
            await syncSessionEventsFromServer()
        }
    }


    func handleBrowserFrameResult(_ result: BrowserFramePlugin.Result) {
        // Delegate to browser coordinator for frame handling
        handleBrowserFrame(frameData: result.frameData)
    }

    func handleSubagentSpawnedResult(_ result: SubagentSpawnedPlugin.Result) {
        logger.info("Subagent spawned: \(result.subagentSessionId) for task: \(result.task.prefix(50))...", category: .chat)

        // Track in subagent state
        subagentState.trackSpawn(
            toolCallId: result.toolCallId ?? result.subagentSessionId,
            subagentSessionId: result.subagentSessionId,
            task: result.task,
            model: result.model
        )

        // Find and update the SpawnSubagent tool call message to show as subagent chip
        updateToolMessageToSubagentChip(
            toolCallId: result.toolCallId ?? result.subagentSessionId,
            subagentSessionId: result.subagentSessionId
        )
    }

    func handleSubagentStatusResult(_ result: SubagentStatusPlugin.Result) {
        logger.debug("Subagent status: \(result.subagentSessionId) - \(result.status) turn \(result.currentTurn)", category: .chat)

        let status: SubagentStatus = result.status == "running" ? .running : .spawning
        subagentState.updateStatus(
            subagentSessionId: result.subagentSessionId,
            status: status,
            currentTurn: result.currentTurn
        )

        updateSubagentMessageContent(subagentSessionId: result.subagentSessionId)
    }

    func handleSubagentCompletedResult(_ result: SubagentCompletedPlugin.Result) {
        logger.info("Subagent completed: \(result.subagentSessionId) in \(result.totalTurns) turns, \(result.duration)ms", category: .chat)

        subagentState.complete(
            subagentSessionId: result.subagentSessionId,
            resultSummary: result.resultSummary,
            fullOutput: result.fullOutput,
            totalTurns: result.totalTurns,
            duration: result.duration,
            tokenUsage: result.tokenUsage
        )

        updateSubagentMessageContent(subagentSessionId: result.subagentSessionId)
    }

    func handleSubagentFailedResult(_ result: SubagentFailedPlugin.Result) {
        logger.error("Subagent failed: \(result.subagentSessionId) - \(result.error)", category: .chat)

        subagentState.fail(
            subagentSessionId: result.subagentSessionId,
            error: result.error,
            duration: result.duration
        )

        updateSubagentMessageContent(subagentSessionId: result.subagentSessionId)
    }

    func handleSubagentForwardedEventResult(_ result: SubagentEventPlugin.Result) {
        logger.debug("Subagent forwarded event: \(result.subagentSessionId) - \(result.innerEventType)", category: .chat)

        subagentState.addForwardedEvent(
            subagentSessionId: result.subagentSessionId,
            eventType: result.innerEventType,
            eventData: result.innerEventData,
            timestamp: result.innerEventTimestamp
        )
    }


    // MARK: - Subagent Helpers

    private func updateToolMessageToSubagentChip(toolCallId: String, subagentSessionId: String) {
        guard let data = subagentState.getSubagent(sessionId: subagentSessionId) else {
            logger.warning("No subagent data found for session \(subagentSessionId)", category: .chat)
            return
        }

        if let index = MessageFinder.indexOfSpawnSubagentTool(toolCallId: toolCallId, in: messages) {
            messages[index].content = .subagent(data)
            messageWindowManager.updateMessage(messages[index])
            logger.debug("Converted tool message to subagent chip for \(subagentSessionId)", category: .chat)
        }
    }

    private func updateSubagentMessageContent(subagentSessionId: String) {
        guard let data = subagentState.getSubagent(sessionId: subagentSessionId) else {
            return
        }

        if let index = MessageFinder.indexBySubagentSessionId(subagentSessionId, in: messages) {
            messages[index].content = .subagent(data)
            messageWindowManager.updateMessage(messages[index])
        }
    }
}
