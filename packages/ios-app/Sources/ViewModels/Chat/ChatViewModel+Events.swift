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

        // Once text starts streaming, thinking is no longer active
        markThinkingMessageCompleteIfNeeded()

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
        // With adaptive thinking, text deltas may arrive before thinking deltas,
        // so we insert before any existing streaming message to maintain visual order.
        if thinkingMessageId == nil {
            let thinkingMessage = ChatMessage.thinking(result.thinkingText, isStreaming: true)

            if let streamingId = streamingManager.streamingMessageId,
               let streamingIndex = MessageFinder.indexById(streamingId, in: messages) {
                // Streaming message already exists (adaptive thinking sent text first)
                // Insert thinking BEFORE it so thinking appears above text visually
                messages.insert(thinkingMessage, at: streamingIndex)
                messageWindowManager.insertMessage(thinkingMessage, before: streamingId)
                logger.debug("Inserted thinking message before streaming: \(thinkingMessage.id)", category: .events)
            } else {
                messages.append(thinkingMessage)
                messageWindowManager.appendMessage(thinkingMessage)
                logger.debug("Created thinking message: \(thinkingMessage.id)", category: .events)
            }
            thinkingMessageId = thinkingMessage.id
        } else if let id = thinkingMessageId,
                  let index = MessageFinder.indexById(id, in: messages) {
            // Update existing thinking message with accumulated content
            messages[index].content = .thinking(visible: result.thinkingText, isExpanded: false, isStreaming: true)
        }

        // Also route to ThinkingState for sheet/history functionality
        thinkingState.handleThinkingDelta(delta)

        logger.verbose("Thinking delta: +\(delta.count) chars, total: \(result.thinkingText.count)", category: .events)
    }

    func handleToolGenerating(_ pluginResult: ToolGeneratingPlugin.Result) {
        toolEventCoordinator.handleToolGenerating(pluginResult, context: self)
    }

    func handleToolStart(_ pluginResult: ToolStartPlugin.Result) {
        // Process through handler (classifies tool type, parses params)
        let result = eventHandler.handleToolStart(pluginResult, context: self)

        // Delegate to coordinator for all tool start handling
        toolEventCoordinator.handleToolStart(pluginResult, result: result, context: self)
    }

    func handleToolOutput(_ result: ToolOutputPlugin.Result) {
        guard let index = MessageFinder.lastIndexOfToolUse(
            toolCallId: result.toolCallId, in: messages
        ) else { return }

        if case .toolUse(var tool) = messages[index].content {
            let accumulated = (tool.streamingOutput ?? "") + result.output
            let (truncated, _) = ResultTruncation.truncate(accumulated)
            tool.streamingOutput = truncated
            messages[index].content = .toolUse(tool)
            messageWindowManager.updateMessage(messages[index])
        }
    }

    func handleToolEnd(_ pluginResult: ToolEndPlugin.Result) {
        // Process through handler (extracts status and result)
        let result = eventHandler.handleToolEnd(pluginResult)

        // Check if this is a browser tool result with screenshot data
        // (Extract screenshot before coordinator - needs access to BrowserScreenshotService)
        if let index = MessageFinder.lastIndexOfToolUse(toolCallId: result.toolCallId, in: messages) {
            if case .toolUse(let tool) = messages[index].content {
                if ToolKind(toolName: tool.toolName) == .browseTheWeb {
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
        if browserState.dismissal != .userDismissed && !browserState.showBrowserWindow {
            browserState.showBrowserWindow = true
        }
    }

    func handleTurnStart(_ pluginResult: TurnStartPlugin.Result) {
        // A turn starting means the agent is actively processing.
        // Also clears any stale postProcessing state from a previous cycle.
        agentPhase = .processing

        if isCompacting {
            isCompacting = false
            compactionInProgressMessageId = nil
        }

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

        // Auto-dismiss browser sheet when agent completes
        if browserState.showBrowserWindow {
            browserState.dismissal = .autoDismissed
            browserState.showBrowserWindow = false
        }

        // Delegate to coordinator for all completion handling
        turnLifecycleCoordinator.handleComplete(streamingText: finalStreamingText, context: self)

        // Enter post-processing state: text field enabled, send button disabled.
        // Cleared by agent_ready event when background hooks finish.
        agentPhase = .postProcessing

        // Defensive timeout: if agent.ready never arrives, recover the send button
        postProcessingTimeoutTask?.cancel()
        postProcessingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            if self.agentPhase == .postProcessing {
                self.logWarning("Post-processing timeout — agent.ready never arrived, recovering")
                self.agentPhase = .idle
            }
        }
    }

    func handleAgentReady() {
        postProcessingTimeoutTask?.cancel()
        postProcessingTimeoutTask = nil
        agentPhase = .idle
        logInfo("Agent ready - post-processing complete")
    }

    func handleCompactionStarted(_ pluginResult: CompactionStartedPlugin.Result) {
        logger.info("Compaction started (reason: \(pluginResult.reason))", category: .events)

        // Block the send button while compaction runs
        isCompacting = true

        // Finalize any current streaming before adding notification
        flushPendingTextUpdates()
        finalizeStreamingMessage()

        // Add spinning "Compacting..." pill to chat
        let inProgressMessage = ChatMessage.compactionInProgress(reason: pluginResult.reason)
        messages.append(inProgressMessage)
        compactionInProgressMessageId = inProgressMessage.id
    }

    func handleCompaction(_ pluginResult: CompactionPlugin.Result) {
        // Process event through handler
        let result = eventHandler.handleCompaction(pluginResult)
        logger.info("Context compacted: \(result.tokensBefore) -> \(result.tokensAfter) tokens (saved \(result.tokensSaved), reason: \(result.reason))", category: .events)

        // Clear compaction blocking state
        isCompacting = false

        // Finalize any current streaming before adding notification
        flushPendingTextUpdates()
        finalizeStreamingMessage()

        // Update context tracking — prefer estimatedContextTokens (total context including
        // system prompt, tools, rules) over tokensAfter (messages-only) for accurate pill display
        let postCompactionTokens = result.estimatedContextTokens ?? result.tokensAfter
        contextState.lastTurnInputTokens = postCompactionTokens
        logger.debug("Updated lastTurnInputTokens to \(postCompactionTokens) after compaction", category: .events)

        // Replace the in-progress pill with the final compaction pill
        if let inProgressId = compactionInProgressMessageId,
           let index = MessageFinder.indexById(inProgressId, in: messages) {
            let compactionMessage = ChatMessage.compaction(
                tokensBefore: result.tokensBefore,
                tokensAfter: result.tokensAfter,
                reason: result.reason,
                summary: result.summary
            )
            messages[index] = compactionMessage
            compactionInProgressMessageId = nil
        } else {
            // No in-progress pill found (e.g. reconstruction) — just append
            let compactionMessage = ChatMessage.compaction(
                tokensBefore: result.tokensBefore,
                tokensAfter: result.tokensAfter,
                reason: result.reason,
                summary: result.summary
            )
            messages.append(compactionMessage)
        }

        // Refresh context from server to ensure context limit is also current
        Task {
            await refreshContextFromServer()
        }
    }

    func handleMemoryUpdating(_ pluginResult: MemoryUpdatingPlugin.Result) {
        logger.info("Memory updating started", category: .events)

        flushPendingTextUpdates()
        finalizeStreamingMessage()

        let inProgressMessage = ChatMessage.memoryUpdating()
        messages.append(inProgressMessage)
        memoryUpdatingInProgressMessageId = inProgressMessage.id
    }

    func handleMemoryUpdated(_ pluginResult: MemoryUpdatedPlugin.Result) {
        logger.info("Memory updated: \(pluginResult.title) (type: \(pluginResult.entryType))", category: .events)

        // "skipped" means ledger write determined nothing worth retaining
        // Transition spinner → "Nothing new to retain" briefly, then auto-remove
        if pluginResult.entryType == "skipped" {
            if let inProgressId = memoryUpdatingInProgressMessageId,
               let index = MessageFinder.indexById(inProgressId, in: messages) {
                withAnimation(.smooth(duration: 0.35)) {
                    messages[index].content = .memoryUpdated(title: "Nothing new to retain", entryType: "skipped")
                }
                let messageId = inProgressId
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    if let idx = MessageFinder.indexById(messageId, in: messages) {
                        _ = withAnimation(.smooth(duration: 0.3)) {
                            messages.remove(at: idx)
                        }
                    }
                }
            }
            memoryUpdatingInProgressMessageId = nil
            return
        }

        // Mutate content in-place to keep the same message identity → smooth animation
        if let inProgressId = memoryUpdatingInProgressMessageId,
           let index = MessageFinder.indexById(inProgressId, in: messages) {
            withAnimation(.smooth(duration: 0.35)) {
                messages[index].content = .memoryUpdated(title: pluginResult.title, entryType: pluginResult.entryType)
            }
            memoryUpdatingInProgressMessageId = nil
        } else {
            // No in-progress pill (e.g. reconstruction) — just append
            let message = ChatMessage.memoryUpdated(
                title: pluginResult.title,
                entryType: pluginResult.entryType
            )
            messages.append(message)
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

    /// Handle enriched provider errors from the agent.error event.
    /// Only terminal errors reach here (retries are silent).
    /// Resets all processing state and shows error notification pill.
    func handleProviderError(_ result: ErrorPlugin.Result) {
        uiUpdateQueue.flush()
        uiUpdateQueue.reset()
        animationCoordinator.resetToolState()
        streamingManager.reset()

        agentPhase = .idle
        isCompacting = false
        compactionInProgressMessageId = nil
        memoryUpdatingInProgressMessageId = nil
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
        eventStoreManager?.updateSessionDashboardInfo(
            sessionId: sessionId,
            lastAssistantResponse: "Error: \(String(result.message.prefix(100)))"
        )
        finalizeStreamingMessage()
        closeBrowserSession()

        if let category = result.category, category != "unknown" {
            let data = ProviderErrorDetailData(
                provider: result.provider ?? "unknown",
                category: category,
                message: result.message,
                suggestion: result.suggestion,
                retryable: result.retryable ?? false,
                statusCode: result.statusCode,
                errorType: result.errorType,
                model: result.model
            )
            messages.append(.providerError(data))
            logger.error("Provider error [\(category)]: \(result.message)", category: .events)
        } else {
            // Legacy (un-enriched server): fall back to plain error text
            messages.append(.error(result.message))
            logger.error("Agent error: \(result.message)", category: .events)
        }
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

        agentPhase = .idle
        isCompacting = false
        compactionInProgressMessageId = nil
        memoryUpdatingInProgressMessageId = nil
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

    // MARK: - Task Event Handlers

    func handleTaskCreated(_ result: TaskCreatedPlugin.Result) {
        logger.debug("Task created: \(result.taskId)", category: .events)
        Task { await refreshTasks() }
    }

    func handleTaskUpdated(_ result: TaskUpdatedPlugin.Result) {
        logger.debug("Task updated: \(result.taskId)", category: .events)
        Task { await refreshTasks() }
    }

    func handleTaskDeleted(_ result: TaskDeletedPlugin.Result) {
        logger.debug("Task deleted: \(result.taskId)", category: .events)
        taskState.removeTask(id: result.taskId)
    }

    func handleProjectCreated(_ result: ProjectCreatedPlugin.Result) {
        logger.debug("Project created: \(result.projectId)", category: .events)
        Task { await refreshTasks() }
    }

    func handleProjectDeleted(_ result: ProjectDeletedPlugin.Result) {
        logger.debug("Project deleted: \(result.projectId)", category: .events)
        Task { await refreshTasks() }
    }

    func handleAreaCreated(_ result: AreaCreatedPlugin.Result) {
        logger.debug("Area created: \(result.areaId)", category: .events)
        Task { await refreshTasks() }
    }

    func handleAreaUpdated(_ result: AreaUpdatedPlugin.Result) {
        logger.debug("Area updated: \(result.areaId)", category: .events)
        Task { await refreshTasks() }
    }

    func handleAreaDeleted(_ result: AreaDeletedPlugin.Result) {
        logger.debug("Area deleted: \(result.areaId)", category: .events)
        Task { await refreshTasks() }
    }

    private func refreshTasks() async {
        do {
            let result = try await rpcClient.misc.listTasks()
            taskState.updateTasks(result.tasks)
        } catch {
            logger.warning("Failed to refresh tasks: \(error.localizedDescription)", category: .events)
        }
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
            model: result.model,
            blocking: result.blocking
        )

        // Find and update the SpawnSubagent tool call message to show as subagent chip
        updateToolMessageToSubagentChip(
            toolCallId: result.toolCallId ?? result.subagentSessionId,
            subagentSessionId: result.subagentSessionId
        )
    }

    func handleSubagentStatusResult(_ result: SubagentStatusPlugin.Result) {
        logger.debug("Subagent status: \(result.subagentSessionId) - \(result.status) turn \(result.currentTurn)", category: .chat)

        let status: SubagentStatus = .running
        subagentState.updateStatus(
            subagentSessionId: result.subagentSessionId,
            status: status,
            currentTurn: result.currentTurn
        )

        updateSubagentMessageContent(subagentSessionId: result.subagentSessionId)
    }

    func handleSubagentCompletedResult(_ result: SubagentCompletedPlugin.Result) {
        logger.info("Subagent completed: \(result.subagentSessionId) in \(result.totalTurns) turns, \(result.duration)ms, model=\(result.model ?? "unknown")", category: .chat)

        subagentState.complete(
            subagentSessionId: result.subagentSessionId,
            resultSummary: result.resultSummary,
            fullOutput: result.fullOutput,
            totalTurns: result.totalTurns,
            duration: result.duration,
            tokenUsage: result.tokenUsage,
            model: result.model
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

    func handleSubagentResultAvailableResult(_ result: SubagentResultAvailablePlugin.Result) {
        logger.info("Subagent result available: sessionId=\(result.subagentSessionId), success=\(result.success), task=\(result.task.prefix(50))", category: .chat)

        // Blocking subagents deliver results directly via tool result — no notification needed.
        // Server no longer emits these, but guard for backward compat / race conditions.
        if let subagent = subagentState.getSubagent(sessionId: result.subagentSessionId),
           subagent.blocking {
            logger.debug("Skipping notification for blocking subagent: \(result.subagentSessionId)", category: .chat)
            return
        }

        // Mark as pending user action
        subagentState.markResultsPending(subagentSessionId: result.subagentSessionId)
        logger.debug("Marked subagent results as pending: \(result.subagentSessionId)", category: .chat)

        // Get subagent data for task preview
        guard let subagent = subagentState.getSubagent(sessionId: result.subagentSessionId) else {
            logger.warning("Subagent data not found for result available event: \(result.subagentSessionId) - notification will not be shown", category: .chat)
            return
        }

        // Add notification message to chat
        let notification = ChatMessage(
            role: .system,
            content: .systemEvent(.subagentResultAvailable(
                subagentSessionId: result.subagentSessionId,
                taskPreview: subagent.taskPreview,
                success: result.success
            ))
        )
        messages.append(notification)
        messageWindowManager.appendMessage(notification)
        logger.info("Added subagent result notification to chat: \(result.subagentSessionId)", category: .chat)
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

    // MARK: - Subagent Result Sending

    /// Send subagent results to the agent as a user message
    /// Called when user taps "Send" in the subagent detail sheet for pending results
    func sendSubagentResults(_ subagent: SubagentToolData) {
        logger.info("Sending subagent results to agent: sessionId=\(subagent.subagentSessionId), status=\(subagent.status)", category: .chat)

        guard subagent.status == .completed || subagent.status == .failed else {
            logger.warning("Cannot send results for subagent that is not completed/failed: status=\(subagent.status)", category: .chat)
            return
        }

        // Mark as sent
        subagentState.markResultsSent(subagentSessionId: subagent.subagentSessionId)
        logger.debug("Marked subagent results as sent: \(subagent.subagentSessionId)", category: .chat)

        // Dismiss sheet
        subagentState.showDetailSheet = false

        // Compose prompt with context
        let resultContent: String
        if let error = subagent.error {
            resultContent = "Error: \(error)"
        } else if let fullOutput = subagent.fullOutput {
            resultContent = fullOutput
        } else if let summary = subagent.resultSummary {
            resultContent = summary
        } else {
            resultContent = "Completed in \(subagent.currentTurn) turns"
        }

        let prompt = """
        [SUBAGENT RESULTS - Please review and continue]

        A sub-agent I previously spawned has completed. Here are the results:

        **Task:** \(subagent.task)

        **Results:**
        \(resultContent)

        Please review these results and continue with the relevant task.
        """

        // Send as user message
        inputText = prompt
        sendMessage()
        logger.info("Subagent results sent as user message: \(subagent.subagentSessionId)", category: .chat)
    }
}
