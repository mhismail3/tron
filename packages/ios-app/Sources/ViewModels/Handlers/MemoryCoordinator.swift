import Foundation
import SwiftUI

/// Context required by MemoryCoordinator.
@MainActor
protocol MemoryContext: LoggingContext, StreamingManaging, MessageMutating {
    var isRetaining: Bool { get set }
    var memoryRetainInProgressMessageId: UUID? { get set }
}

/// Coordinates memory retention event handling for ChatViewModel.
///
/// Responsibilities:
/// - Handling memory updating/updated/auto-retain-triggered events
/// - Managing in-progress pill → final pill transition, distinguishing
///   automatic (policy-triggered) from manual retentions
@MainActor
final class MemoryCoordinator {

    init() {}

    /// Handle automatic memory retain trigger.
    ///
    /// Fires on `agent.memory_auto_retain_triggered` — always arrives BEFORE
    /// `memory_updating` in the auto path. We append the distinct
    /// "Auto-retaining memory..." pill here and leave a marker so the
    /// subsequent `memory_updating` handler knows the pill already exists.
    func handleMemoryAutoRetainTriggered(
        _ pluginResult: MemoryAutoRetainTriggeredPlugin.Result,
        context: MemoryContext
    ) {
        context.logInfo("Auto-retain triggered (interval=\(pluginResult.intervalFired))")
        context.isRetaining = true

        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        let inProgressMessage = ChatMessage.memoryAutoRetainInProgress(
            intervalFired: pluginResult.intervalFired
        )
        context.appendToMessages(inProgressMessage)
        context.memoryRetainInProgressMessageId = inProgressMessage.id
    }

    /// Handle memory retain started event.
    func handleMemoryUpdating(
        _ pluginResult: MemoryUpdatingPlugin.Result,
        context: MemoryContext
    ) {
        // If an auto-retain pill was already created (the paired
        // `memory_auto_retain_triggered` event always arrives first), keep it
        // rather than stacking a second "Retaining memory..." pill on top.
        if context.memoryRetainInProgressMessageId != nil {
            context.logInfo("Memory retain started (auto pill already in place)")
            context.isRetaining = true
            return
        }

        context.logInfo("Memory retain started")
        context.isRetaining = true

        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        let inProgressMessage = ChatMessage.memoryRetainInProgress()
        context.appendToMessages(inProgressMessage)
        context.memoryRetainInProgressMessageId = inProgressMessage.id
    }

    /// Handle memory retain completed event.
    func handleMemoryUpdated(
        _ pluginResult: MemoryUpdatedPlugin.Result,
        context: MemoryContext
    ) {
        context.isRetaining = false

        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        if let title = pluginResult.title {
            context.logInfo("Memory retained: \(title)")

            // Mutate content in-place to keep the same message identity → smooth animation
            if let inProgressId = context.memoryRetainInProgressMessageId,
               let index = context.messageIndex.index(for: inProgressId) {
                withAnimation(.smooth(duration: 0.35)) {
                    context.messages[index].content = .memoryRetained(title: title, summary: pluginResult.summary)
                }
                context.memoryRetainInProgressMessageId = nil
            } else {
                context.appendToMessages(ChatMessage.memoryRetained(title: title, summary: pluginResult.summary))
            }
        } else {
            context.logInfo("Memory retain: nothing new")

            if let inProgressId = context.memoryRetainInProgressMessageId,
               let index = context.messageIndex.index(for: inProgressId) {
                withAnimation(.smooth(duration: 0.35)) {
                    context.messages[index].content = .memoryRetainedNothingNew
                }
                context.memoryRetainInProgressMessageId = nil
            } else {
                context.appendToMessages(ChatMessage.memoryRetainedNothingNew())
            }
        }
    }
}
