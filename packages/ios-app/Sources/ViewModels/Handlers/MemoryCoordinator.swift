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
/// - Handling memory updating/updated events
/// - Managing in-progress pill → final pill transition
@MainActor
final class MemoryCoordinator {

    init() {}

    /// Handle memory retain started event.
    func handleMemoryUpdating(
        _ pluginResult: MemoryUpdatingPlugin.Result,
        context: MemoryContext
    ) {
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
