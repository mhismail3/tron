import Foundation
import SwiftUI

/// Coordinates turn lifecycle event handling for ChatViewModel.
///
/// Responsibilities:
/// - Handling turn start/end events
/// - Managing turn state (tracking indices, capability invocations)
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
    ///   - pluginResult: The plugin result with turn start data
    ///   - result: The processed result from ChatEventHandler
    ///   - context: The context providing access to state and dependencies
    func handleTurnStart(
        _ pluginResult: TurnStartPlugin.Result,
        context: TurnLifecycleContext
    ) {
        context.logInfo("Turn \(pluginResult.turnNumber) started")

        // Finalize any streaming text from the previous turn
        if context.hasActiveStreaming {
            context.flushPendingTextUpdates()
            context.finalizeStreamingMessage()
        }

        // Clear thinking state for the new turn
        context.thinkingMessageId = nil

        // Notify ThinkingState of new turn (clears previous turn's thinking for sheet)
        context.startThinkingTurn(pluginResult.turnNumber, model: context.currentModel)

        // Clear capability tracking for the new turn
        if !context.currentTurnCapabilityInvocations.isEmpty {
            context.logDebug("Starting Turn \(pluginResult.turnNumber), clearing \(context.currentTurnCapabilityInvocations.count) completed capability records from previous turn")
            context.currentTurnCapabilityInvocations.removeAll()
        }
        if !context.currentCapabilityInvocationMessages.isEmpty {
            context.logDebug("Clearing \(context.currentCapabilityInvocationMessages.count) capability message references from previous turn")
            context.currentCapabilityInvocationMessages.removeAll()
        }

        // Notify UIUpdateQueue of turn boundary (resets capability ordering)
        context.enqueueTurnBoundary(UIUpdateQueue.TurnBoundaryData(
            turnNumber: pluginResult.turnNumber,
            isStart: true
        ))

        // Reset AnimationCoordinator capability state for new turn
        context.resetAnimationCoordinatorCapabilityState()

        // Track turn boundary for multi-turn metadata assignment
        context.turnStartMessageIndex = context.messages.count
        context.firstTextMessageIdForTurn = nil
        context.logDebug("Turn \(pluginResult.turnNumber) boundary set at message index \(context.turnStartMessageIndex ?? -1)")
    }

    // MARK: - Turn End Handling

    /// Handle a turn end event.
    ///
    /// - Parameters:
    ///   - pluginResult: The plugin result with turn end data
    ///   - result: The processed result from ChatEventHandler
    ///   - context: The context providing access to state and dependencies
    func handleTurnEnd(
        _ pluginResult: TurnEndPlugin.Result,
        context: TurnLifecycleContext
    ) {
        // Log token record for debugging
        let hasTokenRecord = pluginResult.tokenRecord != nil
        context.logInfo("Turn \(pluginResult.turnNumber) ended, hasTokenRecord=\(hasTokenRecord)")

        // Log token values if available
        if let record = pluginResult.tokenRecord {
            context.logDebug("TokenRecord: newInput=\(record.computed.newInputTokens) contextWindow=\(record.computed.contextWindowTokens) rawIn=\(record.source.rawInputTokens) rawOut=\(record.source.rawOutputTokens)")
        } else {
            context.logError("[TOKEN-FLOW] iOS: turn_end MISSING tokenRecord (turn=\(pluginResult.turnNumber))")
        }

        // Persist thinking content for this turn (before clearing state)
        Task {
            await context.endThinkingTurn()
        }

        // Update thinking message to mark streaming as complete
        // This removes the pulsing thinking icon and "Thinking" header
        if let id = context.thinkingMessageId,
           let index = MessageFinder.indexById(id, in: context.messages),
           case .thinking(let visible, let isExpanded, _) = context.messages[index].content {
            context.messages[index].content = .thinking(visible: visible, isExpanded: isExpanded, isStreaming: false)
            context.logDebug("Marked thinking message as no longer streaming")
        }

        // Find the message to update with metadata.
        // The stats line renders BELOW the target message, so we must pick the
        // LAST message in the turn to ensure stats appear after all capability chips.
        //
        // Strategy:
        //   1. Active streaming message (text-only turns ending mid-stream)
        //   2. Last assistant message in turn range (text+capabilities, capability-only, or text-only)
        //   3. Tracked first text ID if the turn boundary was cleared early
        var targetIndex: Int?

        if let id = context.streamingMessageId,
           let index = MessageFinder.indexById(id, in: context.messages) {
            targetIndex = index
            context.logDebug("Using streaming message for turn metadata at index \(index)")
        } else if let startIndex = context.turnStartMessageIndex,
                  startIndex < context.messages.count {
            // Find the LAST assistant message in this turn.
            // This ensures the stats line appears after all parallel capability chips,
            // not between the first and second capability invocation.
            for i in startIndex..<context.messages.count {
                if context.messages[i].role == .assistant {
                    switch context.messages[i].content {
                    case .text, .capabilityInvocation:
                        targetIndex = i
                    default:
                        break
                    }
                }
            }
            if let idx = targetIndex {
                context.logDebug("Using last assistant message for turn metadata at index \(idx) (turn=\(pluginResult.turnNumber))")
            }
        } else if let firstTextId = context.firstTextMessageIdForTurn,
                  let index = MessageFinder.indexById(firstTextId, in: context.messages) {
            targetIndex = index
            context.logDebug("Using tracked text message for turn metadata at index \(index)")
        }

        // Update the target message with metadata
        if let index = targetIndex {
            context.messages[index].tokenRecord = pluginResult.tokenRecord
            context.messages[index].model = context.currentModel
            context.messages[index].latencyMs = pluginResult.duration
            context.messages[index].stopReason = pluginResult.stopReason
            context.messages[index].turnNumber = pluginResult.turnNumber

            // Log token record assignment
            if let record = pluginResult.tokenRecord {
                context.logDebug("[TOKEN-FLOW] iOS: stream.turn_end received")
                context.logDebug("  turn=\(pluginResult.turnNumber), newInput=\(record.computed.newInputTokens), contextWindow=\(record.computed.contextWindowTokens), output=\(record.source.rawOutputTokens)")
            } else {
                context.logError("[TOKEN-FLOW] iOS: stream.turn_end MISSING tokenRecord (turn=\(pluginResult.turnNumber))")
            }
        } else {
            context.logWarning("Could not find message to update with turn metadata (turn=\(pluginResult.turnNumber))")
        }

        // Update all assistant messages from this turn with turn number
        if let startIndex = context.turnStartMessageIndex,
           startIndex < context.messages.count {
            for i in startIndex..<context.messages.count where context.messages[i].role == .assistant {
                context.messages[i].turnNumber = pluginResult.turnNumber
            }
        }

        // Clear turn tracking
        context.turnStartMessageIndex = nil
        context.firstTextMessageIdForTurn = nil

        // Update context window if server provides it (ensures iOS stays in sync after model switch)
        if let contextLimit = pluginResult.contextLimit {
            context.setContextStateCurrentContextWindow(contextLimit)
            context.logDebug("Updated context window from turn_end: \(contextLimit)")
        }

        // Server MUST provide tokenRecord for context tracking
        if let record = pluginResult.tokenRecord {
            context.updateContextStateFromTokenRecord(record)
            context.logDebug("[TOKEN-FLOW] iOS: Context state updated from stream.turn_end")
        } else {
            context.logError("[TOKEN-FLOW] iOS: Context tracking stale - no tokenRecord on turn_end")
        }

        // Update token tracking and accumulation
        if let record = pluginResult.tokenRecord {
            let contextSize = record.computed.contextWindowTokens
            context.logInfo("LIVE handleTurnEnd: contextSize=\(contextSize)")

            // Accumulate ALL tokens for billing tracking
            context.accumulateTokens(
                input: record.source.rawInputTokens,
                output: record.source.rawOutputTokens,
                cacheRead: record.source.rawCacheReadTokens,
                cacheCreation: record.source.rawCacheCreationTokens,
                cost: pluginResult.cost ?? 0
            )

            // Update session tokens in database
            Task {
                do {
                    try await context.updateSessionTokens(
                        inputTokens: record.source.rawInputTokens,
                        outputTokens: record.source.rawOutputTokens,
                        lastTurnInputTokens: contextSize,
                        cacheReadTokens: record.source.rawCacheReadTokens,
                        cacheCreationTokens: record.source.rawCacheCreationTokens,
                        cost: pluginResult.cost ?? 0
                    )
                } catch {
                    context.logError("Failed to update session tokens: \(error.localizedDescription)")
                }
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
        context.logInfo("Agent complete, finalizing message (streamingText: \(streamingText.count) chars, capabilityInvocations: \(context.currentTurnCapabilityInvocations.count))")

        // Flush any pending UI updates to ensure all capability results are displayed
        context.flushUIUpdateQueue()
        context.flushPendingTextUpdates()

        // Remove catching-up notification if still present
        context.finalizeStreamingMessage()

        // Update session list with final response
        context.setSessionProcessing(false)
        context.updateSessionActivitySummary(
            lastAssistantResponse: streamingText.isEmpty ? nil : String(streamingText.prefix(200))
        )

        context.currentCapabilityInvocationMessages.removeAll()
        context.currentTurnCapabilityInvocations.removeAll()

        // Reset all manager states
        context.resetUIUpdateQueue()
        context.resetAnimationCoordinatorCapabilityState()
        context.resetStreamingManager()

        // Refresh context from server to ensure accuracy after all operations
        Task {
            await context.refreshContextFromServer()
        }
    }
}
