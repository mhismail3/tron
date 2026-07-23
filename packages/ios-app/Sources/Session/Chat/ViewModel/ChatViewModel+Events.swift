import Foundation
import UIKit
import SwiftUI

// MARK: - Context Protocol Conformances

extension ChatViewModel: CompactionContext, EventDispatchTarget {}

// MARK: - Event Handlers

extension ChatViewModel {

    func handleTextDelta(_ delta: String) {
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

    func handleThinkingDelta(_ delta: String, kind: ThinkingDisplayKind = .thinking) {
        // Route to ThinkingState for accumulation and sheet/history functionality
        thinkingState.handleThinkingDelta(delta, kind: kind)
        let accumulatedText = thinkingState.currentText

        // Create thinking message on first delta (so it appears BEFORE the text response)
        // With adaptive thinking, text deltas may arrive before thinking deltas,
        // so we insert before any existing streaming message to maintain visual order.
        if thinkingMessageId == nil {
            let thinkingMessage = ChatMessage.thinking(
                accumulatedText,
                isStreaming: true,
                kind: kind
            )

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
            updateMessage(at: index) { message in
                message.content = .thinking(
                    visible: accumulatedText,
                    isExpanded: false,
                    isStreaming: true,
                    kind: kind
                )
            }
        }

        logger.verbose("Thinking delta: +\(delta.count) chars, total: \(accumulatedText.count)", category: .events)
    }

    func handleThinkingEnd(_ thinking: String, kind: ThinkingDisplayKind = .thinking) {
        thinkingState.handleThinkingEnd(thinking, kind: kind)
        guard !thinking.isEmpty else {
            markThinkingMessageCompleteIfNeeded()
            return
        }

        if let id = thinkingMessageId,
           let index = messageIndex.index(for: id) {
            updateMessage(at: index) { message in
                message.content = .thinking(
                    visible: thinking,
                    isExpanded: false,
                    isStreaming: false,
                    kind: kind
                )
            }
        } else {
            let thinkingMessage = ChatMessage.thinking(thinking, isStreaming: false, kind: kind)
            if let streamingId = streamingManager.streamingMessageId,
               let streamingIndex = messageIndex.index(for: streamingId) {
                insertInMessages(thinkingMessage, at: streamingIndex)
            } else {
                appendToMessages(thinkingMessage)
            }
            thinkingMessageId = thinkingMessage.id
        }

        logger.verbose("Thinking end: final total \(thinking.count) chars", category: .events)
    }

    func handleToolInvocationGenerating(_ pluginResult: ToolInvocationGeneratingPlugin.Result) {
        toolInvocationCoordinator.handleToolInvocationGenerating(pluginResult, context: self)
    }

    func handleToolInvocationStarted(_ pluginResult: ToolInvocationStartedPlugin.Result) {
        // Delegate directly to coordinator (tool classification absorbed)
        toolInvocationCoordinator.handleToolInvocationStarted(pluginResult, context: self)
    }

    func handleToolInvocationOutput(_ result: ToolInvocationOutputPlugin.Result) {
        guard let index = messageIndex.index(forToolInvocationId: result.invocationId)
            ?? MessageFinder.lastIndexOfToolInvocation(id: result.invocationId, in: messages) else { return }

        if case .toolInvocation(var invocation) = messages[index].content {
            let accumulated = (invocation.logs.last ?? "") + result.output
            invocation.logs = [String(accumulated.prefix(24_000))]
            updateMessage(at: index) { message in
                message.content = .toolInvocation(invocation)
            }
        }
    }

    func handleToolInvocationProgress(_ result: ToolInvocationProgressPlugin.Result) {
        guard let index = messageIndex.index(forToolInvocationId: result.invocationId)
            ?? MessageFinder.lastIndexOfToolInvocation(id: result.invocationId, in: messages) else { return }

        if case .toolInvocation(var invocation) = messages[index].content {
            if let msg = result.message { invocation.progressMessage = msg }
            if let pct = result.percent { invocation.progressPercent = pct }
            if !result.identity.isEmpty {
                invocation.identity = invocation.identity.merging(result.identity)
            }
            updateMessage(at: index) { message in
                message.content = .toolInvocation(invocation)
            }
        }
    }

    func handleToolInvocationCompleted(_ pluginResult: ToolInvocationCompletedPlugin.Result) {
        // Delegate directly to coordinator
        toolInvocationCoordinator.handleToolInvocationCompleted(pluginResult, context: self)
    }

    func handleTurnStart(_ pluginResult: TurnStartPlugin.Result) {
        // A late turn-start must not erase an already accepted Stop request.
        if agentPhase != .stopping {
            agentPhase = .processing
        }
        runningToolInvocationCount = 0

        if isCompacting {
            if let inProgressId = compactionInProgressMessageId,
               let index = messageIndex.index(for: inProgressId) {
                removeFromMessages(at: index)
            }
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

    func handleResponseComplete(_ pluginResult: AgentResponseCompletePlugin.Result) {
        turnLifecycleCoordinator.handleResponseComplete(pluginResult, context: self)
    }

    func handleTurnFailed(_ result: TurnFailedPlugin.Result) {
        guard result.isCancellation else { return }
        appendToMessages(.interrupted())
        logInfo("Turn cancellation received; awaiting agent completion cleanup")
    }

    func handleComplete() {
        // Both normal completion and a server-terminalized Stop converge here.
        guard agentPhase.isActive else { return }

        // Capture streaming text before finalization clears it
        let finalStreamingText = streamingManager.streamingText

        // Clear thinking accumulation (streaming finalization handled by coordinator)
        thinkingState.clearCurrentStreaming()

        // Delegate to coordinator for all completion handling
        turnLifecycleCoordinator.handleComplete(streamingText: finalStreamingText, context: self)

        agentPhase = .idle
    }

    func handleAgentReady() {
        agentPhase = .idle
        logInfo("Agent ready")
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
    }

    func handleStreamRecoveryRequired(_ result: StreamRecoveryRequiredPlugin.Result) {
        logger.warning(
            "Live event continuity lost: reason=\(result.reason), dropped=\(result.droppedEventCount); requesting reconstruction",
            category: .events
        )
        advanceStreamRecoveryRequest()
    }

    func handleCompactionStarted(_ pluginResult: CompactionStartedPlugin.Result) {
        compactionCoordinator.handleCompactionStarted(pluginResult, context: self)
    }

    func handleCompaction(_ pluginResult: CompactionPlugin.Result) {
        compactionCoordinator.handleCompaction(pluginResult, context: self)
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
    }

    func handleMessageDeleted(_ pluginResult: MessageDeletedPlugin.Result) {
        logger.info("Message deleted: targetType=\(pluginResult.targetType), eventId=\(pluginResult.targetEventId)", category: .events)

        // Add message deleted notification pill to chat
        let deletedMessage = ChatMessage.messageDeleted(targetType: pluginResult.targetType)
        appendToMessages(deletedMessage)
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
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
        eventStoreManager?.updateSessionActivitySummary(
            sessionId: sessionId,
            lastAssistantResponse: "Error: \(String(errorPreview.prefix(100)))"
        )
        finalizeStreamingMessage()
    }

    /// Handle enriched provider errors from the live `error` event.
    /// Only terminal errors reach here (retries are silent).
    /// Resets all processing state and shows error notification pill.
    func handleProviderError(_ result: ErrorPlugin.Result) {
        resetToIdleState(errorPreview: result.message)

        if let provider = result.provider,
           let category = result.category,
           let retryable = result.retryable {
            let data = ProviderErrorDetailData(
                provider: provider,
                category: category,
                message: result.message,
                suggestion: result.suggestion,
                retryable: retryable,
                statusCode: result.statusCode,
                errorType: result.errorType,
                model: result.model,
                recoverable: result.recoverable,
                origin: result.origin,
                retryAfterMs: result.retryAfterMs,
                failure: result.failure
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
        appendToMessages(.error(message))

        // NOTE: Do NOT clear ThinkingState here - thinking caption should persist
        // so user can see what was happening before the error (cleared on next turn)
    }

    // MARK: - Plugin Result Handlers
    // These handlers accept plugin Result types directly, bridging the plugin system
    // to the existing event handler infrastructure.

}
