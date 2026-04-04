import Foundation
import UIKit
import SwiftUI

// MARK: - Context Protocol Conformances

extension ChatViewModel: CompactionContext, MemoryContext {
    func refreshContextInBackground() {
        launchBackground { [weak self] in
            await self?.refreshContextFromServer()
        }
    }
}

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
        // Route to ThinkingState for accumulation and sheet/history functionality
        thinkingState.handleThinkingDelta(delta)
        let accumulatedText = thinkingState.currentText

        // Create thinking message on first delta (so it appears BEFORE the text response)
        // With adaptive thinking, text deltas may arrive before thinking deltas,
        // so we insert before any existing streaming message to maintain visual order.
        if thinkingMessageId == nil {
            let thinkingMessage = ChatMessage.thinking(accumulatedText, isStreaming: true)

            if let streamingId = streamingManager.streamingMessageId,
               let streamingIndex = messageIndex.index(for: streamingId) {
                // Streaming message already exists (adaptive thinking sent text first)
                // Insert thinking BEFORE it so thinking appears above text visually
                insertInMessages(thinkingMessage, at: streamingIndex)
                messageWindowManager.insertMessage(thinkingMessage, before: streamingId)
                logger.debug("Inserted thinking message before streaming: \(thinkingMessage.id)", category: .events)
            } else {
                appendToMessages(thinkingMessage)
                messageWindowManager.appendMessage(thinkingMessage)
                logger.debug("Created thinking message: \(thinkingMessage.id)", category: .events)
            }
            thinkingMessageId = thinkingMessage.id
        } else if let id = thinkingMessageId,
                  let index = messageIndex.index(for: id) {
            // Update existing thinking message with accumulated content
            messages[index].content = .thinking(visible: accumulatedText, isExpanded: false, isStreaming: true)
        }

        logger.verbose("Thinking delta: +\(delta.count) chars, total: \(accumulatedText.count)", category: .events)
    }

    func handleToolGenerating(_ pluginResult: ToolGeneratingPlugin.Result) {
        toolEventCoordinator.handleToolGenerating(pluginResult, context: self)
    }

    func handleToolStart(_ pluginResult: ToolStartPlugin.Result) {
        // Delegate directly to coordinator (tool classification absorbed)
        toolEventCoordinator.handleToolStart(pluginResult, context: self)
    }

    func handleToolOutput(_ result: ToolOutputPlugin.Result) {
        guard let index = messageIndex.index(forToolCallId: result.toolCallId)
            ?? MessageFinder.lastIndexOfToolUse(toolCallId: result.toolCallId, in: messages) else { return }

        if case .toolUse(var tool) = messages[index].content {
            let accumulated = (tool.streamingOutput ?? "") + result.output
            let (truncated, _) = ResultTruncation.truncate(accumulated)
            tool.streamingOutput = truncated
            messages[index].content = .toolUse(tool)
            messageWindowManager.updateMessage(messages[index])
        }
    }

    func handleToolEnd(_ pluginResult: ToolEndPlugin.Result) {
        // Delegate directly to coordinator
        toolEventCoordinator.handleToolEnd(pluginResult, context: self)
    }

    func handleTurnStart(_ pluginResult: TurnStartPlugin.Result) {
        // A turn starting means the agent is actively processing.
        // Also clears any stale postProcessing state from a previous cycle.
        agentPhase = .processing
        runningToolCount = 0

        if isCompacting {
            isCompacting = false
            compactionInProgressMessageId = nil
        }

        // StreamingManager is the single source of truth for streaming state
        // (eventHandler.resetStreamingState was only resetting duplicate state)

        // Delegate to coordinator for all turn start handling
        turnLifecycleCoordinator.handleTurnStart(pluginResult, context: self)
    }

    func handleTurnEnd(_ pluginResult: TurnEndPlugin.Result) {
        // Delegate directly to coordinator — plugin result fields match
        turnLifecycleCoordinator.handleTurnEnd(pluginResult, context: self)
        // Prune old messages from SwiftUI observation to prevent memory pressure in long sessions
        pruneOldMessagesIfNeeded()
    }

    func handleComplete() {
        // Capture streaming text before finalization clears it
        let finalStreamingText = streamingManager.streamingText

        // Clear thinking accumulation (streaming finalization handled by coordinator)
        thinkingState.clearCurrentStreaming()

        // End any active display stream.
        if displayStreamState.isStreamActive {
            endDisplayStream()
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
                self.drainMessageQueue()
            }
        }
    }

    func handleAgentReady() {
        postProcessingTimeoutTask?.cancel()
        postProcessingTimeoutTask = nil
        agentPhase = .idle
        logInfo("Agent ready - post-processing complete")
        drainMessageQueue()
    }

    func handleServerRestarting(_ result: ServerRestartingPlugin.Result) {
        logger.info("Server restarting: reason=\(result.reason), commit=\(result.commit), expectedMs=\(result.restartExpectedMs)", category: .events)

        // Reset processing state — the server is shutting down, so any in-progress
        // agent run is about to be interrupted. Clear state now for a clean slate.
        if agentPhase != .idle {
            agentPhase = .idle
        }
        isCompacting = false
        compactionInProgressMessageId = nil
        isRetaining = false
        memoryRetainInProgressMessageId = nil
        postProcessingTimeoutTask?.cancel()
        postProcessingTimeoutTask = nil
        // Clear queue — server context is lost, queued messages are stale
        messageQueueState.clear()
    }

    func handleCompactionStarted(_ pluginResult: CompactionStartedPlugin.Result) {
        compactionCoordinator.handleCompactionStarted(pluginResult, context: self)
    }

    func handleCompaction(_ pluginResult: CompactionPlugin.Result) {
        compactionCoordinator.handleCompaction(pluginResult, context: self)
    }

    func handleMemoryUpdating(_ pluginResult: MemoryUpdatingPlugin.Result) {
        memoryCoordinator.handleMemoryUpdating(pluginResult, context: self)
    }

    func handleMemoryUpdated(_ pluginResult: MemoryUpdatedPlugin.Result) {
        memoryCoordinator.handleMemoryUpdated(pluginResult, context: self)
    }

    func handleContextCleared(_ pluginResult: ContextClearedPlugin.Result) {
        let tokensFreed = pluginResult.tokensBefore - pluginResult.tokensAfter
        logger.info("Context cleared: \(pluginResult.tokensBefore) -> \(pluginResult.tokensAfter) tokens (freed \(tokensFreed))", category: .events)

        // Finalize any current streaming before adding notification
        flushPendingTextUpdates()
        finalizeStreamingMessage()

        // Update context tracking - the new context size is tokensAfter
        contextState.lastTurnInputTokens = pluginResult.tokensAfter
        logger.debug("Updated lastTurnInputTokens to \(pluginResult.tokensAfter) after context clear", category: .events)

        // Add context cleared notification pill to chat
        let clearedMessage = ChatMessage.contextCleared(
            tokensBefore: pluginResult.tokensBefore,
            tokensAfter: pluginResult.tokensAfter
        )
        appendToMessages(clearedMessage)

        // Refresh context from server to ensure context limit is also current
        launchBackground { [weak self] in
            await self?.refreshContextFromServer()
        }
    }

    func handleMessageDeleted(_ pluginResult: MessageDeletedPlugin.Result) {
        logger.info("Message deleted: targetType=\(pluginResult.targetType), eventId=\(pluginResult.targetEventId)", category: .events)

        // Add message deleted notification pill to chat
        let deletedMessage = ChatMessage.messageDeleted(targetType: pluginResult.targetType)
        appendToMessages(deletedMessage)
    }

    func handleSkillActivated(_ pluginResult: SkillActivatedPlugin.Result) {
        logger.info("Skill activated: \(pluginResult.skillName) (\(pluginResult.source))", category: .events)

        // Refresh context from server - skill activation changes context size
        launchBackground { [weak self] in
            await self?.refreshContextFromServer()
        }
    }

    func handleSkillDeactivated(_ pluginResult: SkillDeactivatedPlugin.Result) {
        logger.info("Skill deactivated: \(pluginResult.skillName)", category: .events)

        // Refresh context from server - skill deactivation changes context size
        launchBackground { [weak self] in
            await self?.refreshContextFromServer()
        }
    }

    func handleSpellCast(_ pluginResult: SpellCastPlugin.Result) {
        logger.info("Spell cast: \(pluginResult.spellName) (\(pluginResult.source))", category: .events)
    }

    func handleRulesActivated(_ pluginResult: RulesActivatedPlugin.Result) {
        let dirs = pluginResult.rules.map(\.scopeDir).joined(separator: ", ")
        logger.info("Rules activated for: \(dirs)", category: .events)

        let message = ChatMessage.rulesActivated(
            rules: pluginResult.rules,
            totalActivated: pluginResult.totalActivated
        )
        appendToMessages(message)

        launchBackground { [weak self] in
            await self?.refreshContextFromServer()
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
        isRetaining = false
        memoryRetainInProgressMessageId = nil
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
        eventStoreManager?.updateSessionDashboardInfo(
            sessionId: sessionId,
            lastAssistantResponse: "Error: \(String(result.message.prefix(100)))"
        )
        finalizeStreamingMessage()

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
            appendToMessages(.providerError(data))
            logger.error("Provider error [\(category)]: \(result.message)", category: .events)
        } else {
            // Legacy (un-enriched server): fall back to plain error text
            appendToMessages(.error(result.message))
            logger.error("Agent error: \(result.message)", category: .events)
        }

        // Drain queued messages if any — agent is idle now
        drainMessageQueue()
    }

    /// Handle errors from the agent streaming (shows error in chat)
    func handleAgentError(_ message: String) {
        logger.error("Agent error: \(message)", category: .events)

        // Flush and reset all manager states on error
        uiUpdateQueue.flush()
        uiUpdateQueue.reset()
        animationCoordinator.resetToolState()
        streamingManager.reset()

        agentPhase = .idle
        isCompacting = false
        compactionInProgressMessageId = nil
        isRetaining = false
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
        eventStoreManager?.updateSessionDashboardInfo(
            sessionId: sessionId,
            lastAssistantResponse: "Error: \(String(message.prefix(100)))"
        )
        finalizeStreamingMessage()
        appendToMessages(.error(message))

        // NOTE: Do NOT clear ThinkingState here - thinking caption should persist
        // so user can see what was happening before the error (cleared on next turn)

        // Drain queued messages if any — agent is idle now
        drainMessageQueue()
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
        launchBackground { [weak self] in
            await self?.syncSessionEventsFromServer()
        }
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
        if let subagent = subagentState.getSubagent(sessionId: result.subagentSessionId),
           subagent.blocking {
            logger.debug("Skipping notification for blocking subagent: \(result.subagentSessionId)", category: .chat)
            return
        }

        // Agent is active — backend delivers results via system prompt injection,
        // so no iOS-side action needed. Just skip the notification.
        if agentPhase != .idle {
            logger.info("Subagent completed during active turn, backend handles delivery: \(result.subagentSessionId)", category: .chat)
            return
        }

        // Agent is idle — show notification for manual review
        subagentState.markResultsPending(subagentSessionId: result.subagentSessionId)
        logger.debug("Marked subagent results as pending: \(result.subagentSessionId)", category: .chat)

        guard let subagent = subagentState.getSubagent(sessionId: result.subagentSessionId) else {
            logger.warning("Subagent data not found for result available event: \(result.subagentSessionId) - notification will not be shown", category: .chat)
            return
        }

        let notification = ChatMessage(
            role: .system,
            content: .systemEvent(.subagentResultAvailable(
                subagentSessionId: result.subagentSessionId,
                taskPreview: subagent.taskPreview,
                success: result.success
            ))
        )
        appendToMessages(notification)
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
