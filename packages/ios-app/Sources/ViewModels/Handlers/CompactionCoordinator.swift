import Foundation
import SwiftUI

/// Context required by CompactionCoordinator.
@MainActor
protocol CompactionContext: LoggingContext, StreamingManaging, MessageMutating {
    var isCompacting: Bool { get set }
    var compactionInProgressMessageId: UUID? { get set }
    var contextState: ContextTrackingState { get }
    func refreshContextInBackground()
}

/// Coordinates context compaction event handling for ChatViewModel.
///
/// Responsibilities:
/// - Handling compaction start/complete events
/// - Managing in-progress pill → final pill transition
/// - Updating context token tracking after compaction
@MainActor
final class CompactionCoordinator {

    init() {}

    /// Handle compaction started event.
    func handleCompactionStarted(
        _ pluginResult: CompactionStartedPlugin.Result,
        context: CompactionContext
    ) {
        context.logInfo("Compaction started (reason: \(pluginResult.reason))")

        context.isCompacting = true

        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        removeInProgressMessage(context)
        let inProgressMessage = ChatMessage.compactionInProgress(reason: pluginResult.reason)
        context.appendToMessages(inProgressMessage)
        context.compactionInProgressMessageId = inProgressMessage.id
    }

    /// Handle compaction complete event.
    func handleCompaction(
        _ pluginResult: CompactionPlugin.Result,
        context: CompactionContext
    ) {
        let tokensSaved = pluginResult.tokensBefore - pluginResult.tokensAfter
        context.logInfo("Context compacted: \(pluginResult.tokensBefore) -> \(pluginResult.tokensAfter) tokens (saved \(tokensSaved))")

        context.isCompacting = false

        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        guard pluginResult.success else {
            if pluginResult.isNoOp {
                removeInProgressMessage(context)
            } else {
                let failedMessage = ChatMessage(
                    role: .system,
                    content: .turnFailed(
                        error: pluginResult.summary?.nilIfEmpty ?? "Context compaction failed",
                        code: "compaction_failed",
                        recoverable: true
                    )
                )
                replaceInProgressMessage(failedMessage, context)
            }
            context.refreshContextInBackground()
            return
        }

        // Update context tracking — prefer estimatedContextTokens (total context including
        // system prompt, capabilities, rules) over tokensAfter (messages-only)
        let postCompactionTokens = pluginResult.estimatedContextTokens ?? pluginResult.tokensAfter
        context.contextState.lastTurnInputTokens = postCompactionTokens

        // Mutate content in-place to keep the same message identity → smooth animation
        let compactionMessage = ChatMessage.compaction(
            tokensBefore: pluginResult.tokensBefore,
            tokensAfter: pluginResult.tokensAfter,
            reason: pluginResult.reason,
            summary: pluginResult.summary,
            preservedTurns: pluginResult.preservedTurns,
            summarizedTurns: pluginResult.summarizedTurns
        )
        replaceInProgressMessage(compactionMessage, context)

        context.refreshContextInBackground()
    }

    private func replaceInProgressMessage(
        _ replacement: ChatMessage,
        _ context: CompactionContext
    ) {
        if let inProgressId = context.compactionInProgressMessageId,
           let index = context.messageIndex.index(for: inProgressId) {
            withAnimation(.smooth(duration: 0.35)) {
                context.messages[index].content = replacement.content
            }
            context.compactionInProgressMessageId = nil
        } else {
            context.appendToMessages(replacement)
        }
    }

    private func removeInProgressMessage(_ context: CompactionContext) {
        let trackedId = context.compactionInProgressMessageId
        context.removeFromMessages { message in
            if message.id == trackedId {
                return true
            }
            if case .systemEvent(.compactionInProgress) = message.content {
                return true
            }
            return false
        }
        context.compactionInProgressMessageId = nil
    }
}

private extension CompactionPlugin.Result {
    var isNoOp: Bool {
        !success && summary?.hasPrefix("Compaction skipped:") == true
    }
}
