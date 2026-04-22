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
                logger.debug("Inserted thinking message before streaming: \(thinkingMessage.id) (before \(streamingId))", category: .events)
            } else {
                appendToMessages(thinkingMessage)
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
        }
    }

    func handleToolProgress(_ result: ToolProgressPlugin.Result) {
        guard let index = messageIndex.index(forToolCallId: result.toolCallId)
            ?? MessageFinder.lastIndexOfToolUse(toolCallId: result.toolCallId, in: messages) else { return }

        if case .toolUse(var tool) = messages[index].content {
            if let msg = result.message { tool.progressMessage = msg }
            if let pct = result.percent { tool.progressPercent = pct }
            messages[index].content = .toolUse(tool)
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
        pullUpPanelState.awaitingSuggestions = false

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
        // Only transition from .processing → .postProcessing.
        // After abort, agentPhase is already .idle — skip to prevent flicker.
        guard agentPhase == .processing else { return }

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
        pullUpPanelState.awaitingSuggestions = true

        // Safety-net timeout: server guarantees agent.ready delivery (hooks are fail-open),
        // so this only fires on network delivery failure (WebSocket drop during background).
        // Warning at 15s to aid diagnostics, recovery at 30s.
        postProcessingTimeoutTask?.cancel()
        postProcessingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled else { return }
            if self.agentPhase == .postProcessing {
                self.logWarning("Post-processing: 15s without agent.ready — server hooks may be slow or WebSocket dropped")
            }

            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            if self.agentPhase == .postProcessing {
                self.logWarning("Post-processing timeout (30s) — agent.ready never arrived, recovering")
                self.agentPhase = .idle
            }
        }
    }

    func handleAgentReady() {
        postProcessingTimeoutTask?.cancel()
        postProcessingTimeoutTask = nil
        agentPhase = .idle
        logInfo("Agent ready - post-processing complete")
        // Queue drain is now server-side — no client-side drain needed.
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
        askUserQuestionState.clearAll()
        getConfirmationState.clearAll()
        postProcessingTimeoutTask?.cancel()
        postProcessingTimeoutTask = nil
        pullUpPanelState.awaitingSuggestions = false
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

    func handleMemoryAutoRetainTriggered(_ pluginResult: MemoryAutoRetainTriggeredPlugin.Result) {
        memoryCoordinator.handleMemoryAutoRetainTriggered(pluginResult, context: self)
    }

    func handleMemoryAutoRetainFailed(_ pluginResult: MemoryAutoRetainFailedPlugin.Result) {
        memoryCoordinator.handleMemoryAutoRetainFailed(pluginResult, context: self)
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

    /// Reset all processing state to idle after an error.
    /// Shared by handleProviderError and handleAgentError.
    private func resetToIdleState(errorPreview: String) {
        uiUpdateQueue.flush()
        uiUpdateQueue.reset()
        animationCoordinator.resetToolState()
        streamingManager.reset()

        agentPhase = .idle
        isCompacting = false
        compactionInProgressMessageId = nil
        isRetaining = false
        memoryRetainInProgressMessageId = nil
        askUserQuestionState.clearAll()
        getConfirmationState.clearAll()
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
        eventStoreManager?.updateSessionDashboardInfo(
            sessionId: sessionId,
            lastAssistantResponse: "Error: \(String(errorPreview.prefix(100)))"
        )
        finalizeStreamingMessage()
    }

    /// Handle enriched provider errors from the agent.error event.
    /// Only terminal errors reach here (retries are silent).
    /// Resets all processing state and shows error notification pill.
    func handleProviderError(_ result: ErrorPlugin.Result) {
        resetToIdleState(errorPreview: result.message)

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
            appendToMessages(.error(result.message))
            logger.error("Agent error: \(result.message)", category: .events)
        }
    }

    /// Handle errors from the agent streaming (shows error in chat)
    func handleAgentError(_ message: String) {
        logger.error("Agent error: \(message)", category: .events)

        resetToIdleState(errorPreview: message)
        pullUpPanelState.awaitingSuggestions = false
        appendToMessages(.error(message))

        // NOTE: Do NOT clear ThinkingState here - thinking caption should persist
        // so user can see what was happening before the error (cleared on next turn)
    }

    // MARK: - Plugin Result Handlers
    // These handlers accept plugin Result types directly, bridging the plugin system
    // to the existing event handler infrastructure.


    // MARK: - Queue Event Handlers

    func handleMessageQueued(_ result: MessageQueuedPlugin.Result) {
        let item = PendingQueueItem(
            queueId: result.queueId,
            text: result.text,
            position: result.position,
            timestamp: result.timestamp
        )
        messageQueueState.handleQueued(item)
        logger.info("Message queued: \"\(result.text.prefix(50))...\" position=\(result.position)", category: .events)
    }

    func handleMessageDequeued(_ result: MessageDequeuedPlugin.Result) {
        messageQueueState.handleDequeued(queueId: result.queueId)
        logger.info("Message dequeued: queueId=\(result.queueId) reason=\(result.reason)", category: .events)
    }

    func handleQueuedMessageSent(_ result: QueuedMessageSentPlugin.Result) {
        // Server auto-drained a queued message and is about to run the agent with it.
        // Append a user message bubble so the chat shows the queued text in real-time
        // (same as what happens locally when the user taps Send directly).
        let userMessage = ChatMessage.user(result.text)
        appendToMessages(userMessage)
        currentTurn += 1
        logger.info("Queued message sent as user prompt: \"\(result.text.prefix(50))...\"", category: .events)
    }

}
