import Foundation
import SwiftUI

/// Coordinates turn lifecycle event handling for ChatViewModel.
///
/// Responsibilities:
/// - Handling turn start/response-complete/end events
/// - Managing turn state (tracking indices, tool invocations)
/// - Marking the server-identified final response and attaching its metadata
/// - Coordinating with ThinkingState, ContextState
/// - Managing completion state cleanup
///
/// This coordinator extracts the turn lifecycle logic from ChatViewModel+Events.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class TurnLifecycleCoordinator {
    private var deliveryPresentationTracker =
        AgentDeliveryContinuationPresentationTracker()

    // MARK: - Initialization

    init() {}

    /// Reconstruction is authoritative across reconnect. Seed presentation
    /// state only for an active run so later live frames cannot repeat a
    /// provenance prelude already restored from durable history.
    func restoreDeliveryPresentationState(
        from messages: [ChatMessage],
        runIsActive: Bool
    ) {
        deliveryPresentationTracker.reset()
        guard runIsActive else { return }
        let currentRunStart = messages.lastIndex(where: { $0.role == .user })
            .map { messages.index(after: $0) }
            ?? messages.startIndex
        let provenance = messages[currentRunStart...].flatMap(
            \.agentDeliveryProvenance
        )
        _ = deliveryPresentationTracker.takeUnpresented(provenance)
    }

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

        // Clear tool tracking for the new turn
        if !context.currentTurnToolMessageIds.isEmpty {
            context.logDebug("Clearing \(context.currentTurnToolMessageIds.count) tool message references from previous turn")
            context.currentTurnToolMessageIds.removeAll()
        }

        // Notify UIUpdateQueue of turn boundary (resets tool ordering)
        context.enqueueTurnBoundary(UIUpdateQueue.TurnBoundaryData(
            turnNumber: pluginResult.turnNumber,
            isStart: true
        ))

        // Reset AnimationCoordinator tool state for new turn
        context.resetAnimationCoordinatorToolState()

        // Track turn boundary for multi-turn metadata assignment
        context.turnStartMessageIndex = context.messages.count
        context.firstTextMessageIdForTurn = nil
        let unpresentedProvenance = deliveryPresentationTracker.takeUnpresented(
            pluginResult.agentDeliveryProvenance
        )
        if !unpresentedProvenance.isEmpty {
            context.appendToMessages(
                .deliveryContinuation(
                    unpresentedProvenance,
                    turnNumber: pluginResult.turnNumber
                )
            )
        }
        context.logDebug("Turn \(pluginResult.turnNumber) boundary set at message index \(context.turnStartMessageIndex ?? -1)")
    }

    // MARK: - Response Complete Handling

    /// Mark the textual response that ends the current prompt cycle.
    ///
    /// Provider stop reasons are not finality: a provider may report
    /// `end_turn` while also returning tool invocations. A completed
    /// response with zero invocations is the conservative server-backed signal
    /// for a clean final textual response.
    func handleResponseComplete(
        _ pluginResult: AgentResponseCompletePlugin.Result,
        context: TurnLifecycleContext
    ) {
        guard !pluginResult.hasToolInvocations else {
            context.logDebug(
                "Response for turn \(pluginResult.turnNumber) includes \(pluginResult.toolInvocationCount) tool invocation(s); omitting final-response metadata"
            )
            return
        }

        guard let index = currentResponseTextIndex(in: context) else {
            context.logDebug(
                "Terminal response for turn \(pluginResult.turnNumber) has no textual chat message"
            )
            return
        }

        attachDeliveryProvenanceIfNeeded(
            pluginResult.agentDeliveryProvenance,
            context: context
        )
        context.updateMessage(at: index) { message in
            message.isFinalAssistantResponse = true
            message.turnNumber = pluginResult.turnNumber
        }
        context.logDebug(
            "Marked textual response for turn \(pluginResult.turnNumber) as final"
        )
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
           case .thinking(let visible, let isExpanded, _, let kind) = context.messages[index].content {
            context.updateMessage(at: index) { message in
                message.content = .thinking(
                    visible: visible,
                    isExpanded: isExpanded,
                    isStreaming: false,
                    kind: kind
                )
            }
            context.logDebug("Marked thinking message as no longer streaming")
        }

        // Only the response previously marked by the server's exact
        // response-complete tool signal may own presentation metadata.
        if let index = finalResponseIndex(
            for: pluginResult.turnNumber,
            in: context
        ) {
            context.updateMessage(at: index) { message in
                message.applyFinalAssistantResponseMetadata(
                    tokenRecord: pluginResult.tokenRecord,
                    model: pluginResult.model,
                    latencyMs: pluginResult.duration
                )
                message.turnNumber = pluginResult.turnNumber
            }

            // Log token record assignment
            if let record = pluginResult.tokenRecord {
                context.logDebug("[TOKEN-FLOW] iOS: stream.turn_end received")
                context.logDebug("  turn=\(pluginResult.turnNumber), newInput=\(record.computed.newInputTokens), contextWindow=\(record.computed.contextWindowTokens), output=\(record.source.rawOutputTokens)")
            } else {
                context.logError("[TOKEN-FLOW] iOS: stream.turn_end MISSING tokenRecord (turn=\(pluginResult.turnNumber))")
            }
        }

        // Update all assistant messages from this turn with turn number
        if let startIndex = context.turnStartMessageIndex,
           startIndex < context.messages.count {
            for i in startIndex..<context.messages.count where context.messages[i].role == .assistant {
                context.updateMessage(at: i) { message in
                    message.turnNumber = pluginResult.turnNumber
                }
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

            // Persist ContextTrackingState's accumulated totals with this turn's context size.
            Task {
                do {
                    try await context.persistAccumulatedSessionTokens(
                        lastTurnInputTokens: contextSize
                    )
                } catch {
                    context.logError("Failed to update session tokens: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Locate the current turn's text message without using its visual position
    /// to decide finality. Finality is assigned separately by
    /// `handleResponseComplete`.
    private func currentResponseTextIndex(in context: TurnLifecycleContext) -> Int? {
        if let id = context.streamingMessageId,
           let index = MessageFinder.indexById(id, in: context.messages),
           context.messages[index].role == .assistant,
           !context.messages[index].isDeliveryProvenanceOnly,
           context.messages[index].content.isAssistantResponseText {
            return index
        }

        if let id = context.firstTextMessageIdForTurn,
           let index = MessageFinder.indexById(id, in: context.messages),
           context.messages[index].role == .assistant,
           !context.messages[index].isDeliveryProvenanceOnly,
           context.messages[index].content.isAssistantResponseText {
            return index
        }

        guard let startIndex = context.turnStartMessageIndex,
              startIndex < context.messages.count
        else {
            return nil
        }

        return (startIndex..<context.messages.count).reversed().first {
            context.messages[$0].role == .assistant &&
            !context.messages[$0].isDeliveryProvenanceOnly &&
            context.messages[$0].content.isAssistantResponseText
        }
    }

    /// Older servers expose continuation metadata only at response completion.
    /// Place that fallback on the first assistant row for the turn so its
    /// visual order is still provenance → thinking/tools → response.
    private func attachDeliveryProvenanceIfNeeded(
        _ provenance: [AgentDeliveryMessageProvenance],
        context: TurnLifecycleContext
    ) {
        let startIndex = context.turnStartMessageIndex ?? 0
        let unpresentedProvenance =
            deliveryPresentationTracker.takeUnpresented(provenance)
        guard !unpresentedProvenance.isEmpty,
              startIndex < context.messages.count else {
            return
        }
        if let existingIndex = (startIndex..<context.messages.count).first(where: {
            !context.messages[$0].agentDeliveryProvenance.isEmpty
        }) {
            context.updateMessage(at: existingIndex) { message in
                message.agentDeliveryProvenance.append(
                    contentsOf: unpresentedProvenance
                )
            }
            return
        }
        guard let firstAssistantIndex = (startIndex..<context.messages.count).first(where: {
            context.messages[$0].role == .assistant
        })
        else {
            return
        }
        context.updateMessage(at: firstAssistantIndex) { message in
            message.agentDeliveryProvenance = unpresentedProvenance
        }
    }

    private func finalResponseIndex(
        for turnNumber: Int,
        in context: TurnLifecycleContext
    ) -> Int? {
        guard let index = currentResponseTextIndex(in: context),
              context.messages[index].isFinalAssistantResponse,
              context.messages[index].turnNumber == turnNumber
        else {
            return nil
        }
        return index
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
        context.logInfo("Agent complete, finalizing message (streamingText: \(streamingText.count) chars, toolInvocations: \(context.currentTurnToolMessageIds.count))")

        // Flush any pending UI updates to ensure all tool results are displayed
        context.flushUIUpdateQueue()
        context.flushPendingTextUpdates()

        // Remove catching-up notification if still present
        context.finalizeStreamingMessage()

        // Update session list with final response
        context.setSessionProcessing(false)
        context.updateSessionActivitySummary(
            lastAssistantResponse: streamingText.isEmpty ? nil : String(streamingText.prefix(200))
        )

        context.currentTurnToolMessageIds.removeAll()
        deliveryPresentationTracker.reset()

        // Reset all manager states
        context.resetUIUpdateQueue()
        context.resetAnimationCoordinatorToolState()
        context.resetStreamingManager()
    }
}
