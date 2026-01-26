import Foundation
import SwiftUI

/// Coordinates turn lifecycle event handling for ChatViewModel.
///
/// Responsibilities:
/// - Handling turn start/end events
/// - Managing turn state (tracking indices, tool calls)
/// - Updating message metadata with token usage
/// - Coordinating with ThinkingState, ContextState
/// - Managing completion state cleanup
///
/// This coordinator extracts the turn lifecycle logic from ChatViewModel+Events.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class TurnLifecycleCoordinator {

    // MARK: - Initialization

    init() {}

    // MARK: - Turn Start Handling

    /// Handle a turn start event.
    ///
    /// - Parameters:
    ///   - event: The raw turn start event from the server
    ///   - result: The processed result from ChatEventHandler
    ///   - context: The context providing access to state and dependencies
    func handleTurnStart(
        _ event: TurnStartEvent,
        result: TurnStartResult,
        context: TurnLifecycleContext
    ) {
        context.logInfo("Turn \(result.turnNumber) started")

        // Reset AskUserQuestion tracking for the new turn
        context.askUserQuestionCalledInTurn = false

        // Finalize any streaming text from the previous turn
        if context.hasActiveStreaming {
            context.flushPendingTextUpdates()
            context.finalizeStreamingMessage()
        }

        // Clear thinking state for the new turn
        context.thinkingMessageId = nil

        // Notify ThinkingState of new turn (clears previous turn's thinking for sheet)
        context.startThinkingTurn(result.turnNumber, model: context.currentModel)

        // Clear tool tracking for the new turn
        if !context.currentTurnToolCalls.isEmpty {
            context.logDebug("Starting Turn \(result.turnNumber), clearing \(context.currentTurnToolCalls.count) completed tool records from previous turn")
            context.currentTurnToolCalls.removeAll()
        }
        if !context.currentToolMessages.isEmpty {
            context.logDebug("Clearing \(context.currentToolMessages.count) tool message references from previous turn")
            context.currentToolMessages.removeAll()
        }

        // Notify UIUpdateQueue of turn boundary (resets tool ordering)
        context.enqueueTurnBoundary(UIUpdateQueue.TurnBoundaryData(
            turnNumber: result.turnNumber,
            isStart: true
        ))

        // Reset AnimationCoordinator tool state for new turn
        context.resetAnimationCoordinatorToolState()

        // Track turn boundary for multi-turn metadata assignment
        context.turnStartMessageIndex = context.messages.count
        context.firstTextMessageIdForTurn = nil
        context.logDebug("Turn \(result.turnNumber) boundary set at message index \(context.turnStartMessageIndex ?? -1)")
    }

    // MARK: - Turn End Handling

    /// Handle a turn end event.
    ///
    /// - Parameters:
    ///   - event: The raw turn end event from the server
    ///   - result: The processed result from ChatEventHandler
    ///   - context: The context providing access to state and dependencies
    func handleTurnEnd(
        _ event: TurnEndEvent,
        result: TurnEndResult,
        context: TurnLifecycleContext
    ) {
        // Log both raw and normalized usage for debugging
        let rawIn = result.tokenUsage?.inputTokens ?? 0
        let rawOut = result.tokenUsage?.outputTokens ?? 0
        let hasNormalized = result.normalizedUsage != nil
        context.logInfo("Turn \(result.turnNumber) ended, tokens: raw_in=\(rawIn) raw_out=\(rawOut) hasNormalizedUsage=\(hasNormalized)")

        // Log normalized values if available (server's pre-calculated values)
        if let normalized = result.normalizedUsage {
            context.logDebug("NormalizedUsage: newInput=\(normalized.newInputTokens) contextWindow=\(normalized.contextWindowTokens) cacheRead=\(normalized.cacheReadTokens)")
        } else {
            context.logDebug("NormalizedUsage not available, will use fallback local calculation")
        }

        // Persist thinking content for this turn (before clearing state)
        Task {
            await context.endThinkingTurn()
        }

        // Update thinking message to mark streaming as complete
        // This removes the spinning brain icon and "Thinking" header
        if let id = context.thinkingMessageId,
           let index = MessageFinder.indexById(id, in: context.messages),
           case .thinking(let visible, let isExpanded, _) = context.messages[index].content {
            context.messages[index].content = .thinking(visible: visible, isExpanded: isExpanded, isStreaming: false)
            context.logDebug("Marked thinking message as no longer streaming")
        }

        // Find the message to update with metadata
        // Priority: streaming message > first text message of turn > fallback search
        var targetIndex: Int?

        if let id = context.streamingMessageId,
           let index = MessageFinder.indexById(id, in: context.messages) {
            targetIndex = index
            context.logDebug("Using streaming message for turn metadata at index \(index)")
        } else if let firstTextId = context.firstTextMessageIdForTurn,
                  let index = MessageFinder.indexById(firstTextId, in: context.messages) {
            // Streaming message was finalized (e.g., before tool call) but we tracked the first text
            targetIndex = index
            context.logDebug("Using tracked first text message for turn metadata at index \(index)")
        } else if let startIndex = context.turnStartMessageIndex,
                  startIndex < context.messages.count {
            // Fallback: find first assistant text message from turn start
            for i in startIndex..<context.messages.count {
                if context.messages[i].role == .assistant,
                   case .text = context.messages[i].content {
                    targetIndex = i
                    context.logDebug("Found first assistant text message at index \(i) for turn metadata")
                    break
                }
            }
        }

        // Update the target message with metadata
        if let index = targetIndex {
            context.messages[index].tokenUsage = result.tokenUsage
            context.messages[index].model = context.currentModel
            context.messages[index].latencyMs = result.durationMs
            context.messages[index].stopReason = result.stopReason
            context.messages[index].turnNumber = result.turnNumber

            // Use server-provided normalizedUsage for incremental tokens (preferred)
            if let normalized = result.normalizedUsage {
                context.messages[index].incrementalTokens = TokenUsage(
                    inputTokens: normalized.newInputTokens,
                    outputTokens: normalized.outputTokens,
                    cacheReadTokens: normalized.cacheReadTokens,
                    cacheCreationTokens: normalized.cacheCreationTokens
                )
                context.logDebug("[TOKEN-FLOW] iOS: stream.turn_end received")
                context.logDebug("  turn=\(result.turnNumber), newInput=\(normalized.newInputTokens), contextWindow=\(normalized.contextWindowTokens), output=\(normalized.outputTokens)")
            } else {
                context.logError("[TOKEN-FLOW] iOS: stream.turn_end MISSING normalizedUsage (turn=\(result.turnNumber))")
            }
        } else {
            context.logWarning("Could not find message to update with turn metadata (turn=\(result.turnNumber))")
        }

        // Update all assistant messages from this turn with turn number
        if let startIndex = context.turnStartMessageIndex,
           startIndex < context.messages.count {
            for i in startIndex..<context.messages.count where context.messages[i].role == .assistant {
                context.messages[i].turnNumber = result.turnNumber
            }
        }

        // Clear turn tracking
        context.turnStartMessageIndex = nil
        context.firstTextMessageIdForTurn = nil

        // Remove catching-up notification at natural breakpoint (turn end)
        if let catchUpId = context.catchingUpMessageId {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                context.messages.removeAll { $0.id == catchUpId }
            }
            context.catchingUpMessageId = nil
            context.logInfo("Catch-up complete - removed notification")
        }

        // Update context window if server provides it (ensures iOS stays in sync after model switch)
        if let contextLimit = result.contextLimit {
            context.setContextStateCurrentContextWindow(contextLimit)
            context.logDebug("Updated context window from turn_end: \(contextLimit)")
        }

        // Server MUST provide normalizedUsage for context tracking
        if let normalized = result.normalizedUsage {
            context.updateContextStateFromNormalizedUsage(normalized)
            context.logDebug("[TOKEN-FLOW] iOS: Context state updated from stream.turn_end")
        } else {
            context.logError("[TOKEN-FLOW] iOS: Context tracking stale - no normalizedUsage on turn_end")
        }

        // Update token tracking and accumulation
        if let usage = result.tokenUsage {
            let contextSize = result.normalizedUsage?.contextWindowTokens ?? 0
            context.logInfo("LIVE handleTurnEnd: contextSize=\(contextSize)")

            // Accumulate ALL tokens for billing tracking
            context.accumulateTokens(
                input: usage.inputTokens,
                output: usage.outputTokens,
                cacheRead: usage.cacheReadTokens ?? 0,
                cacheCreation: usage.cacheCreationTokens ?? 0,
                cost: result.cost ?? 0
            )

            // Update session tokens in database
            do {
                try context.updateSessionTokens(
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    lastTurnInputTokens: contextSize,
                    cacheReadTokens: usage.cacheReadTokens ?? 0,
                    cacheCreationTokens: usage.cacheCreationTokens ?? 0,
                    cost: result.cost ?? 0
                )
            } catch {
                context.logError("Failed to update session tokens: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Complete Handling

    /// Handle agent completion.
    ///
    /// - Parameters:
    ///   - streamingText: The final streaming text (captured before finalization)
    ///   - context: The context providing access to state and dependencies
    func handleComplete(
        streamingText: String,
        context: TurnLifecycleContext
    ) {
        context.logInfo("Agent complete, finalizing message (streamingText: \(streamingText.count) chars, toolCalls: \(context.currentTurnToolCalls.count))")

        // Flush any pending UI updates to ensure all tool results are displayed
        context.flushUIUpdateQueue()
        context.flushPendingTextUpdates()

        context.isProcessing = false

        // Remove catching-up notification if still present
        if let catchUpId = context.catchingUpMessageId {
            context.messages.removeAll { $0.id == catchUpId }
            context.catchingUpMessageId = nil
        }

        context.finalizeStreamingMessage()

        // Reset browser dismiss flag for next turn
        context.userDismissedBrowserThisTurn = false

        // Update dashboard with final response and tool count
        context.setSessionProcessing(false)
        context.updateSessionDashboardInfo(
            lastAssistantResponse: streamingText.isEmpty ? nil : String(streamingText.prefix(200)),
            lastToolCount: context.currentTurnToolCalls.isEmpty ? nil : context.currentTurnToolCalls.count
        )

        context.currentToolMessages.removeAll()
        context.currentTurnToolCalls.removeAll()

        // Reset all manager states
        context.resetUIUpdateQueue()
        context.resetAnimationCoordinatorToolState()
        context.resetStreamingManager()

        // Close browser session when agent completes
        context.closeBrowserSession()

        // Refresh context from server to ensure accuracy after all operations
        Task {
            await context.refreshContextFromServer()
        }
    }
}
