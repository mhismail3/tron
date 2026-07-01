import SwiftUI

/// Renders system events (notifications) in the chat
/// Consolidates rendering for all SystemEvent cases
struct SystemEventView: View {
    let event: SystemEvent
    var onTap: ((MessageBubbleTapAction) -> Void)?

    var body: some View {
        if event.isCompactionNotification {
            compactionNotificationView
        } else {
            eventView
        }
    }

    @ViewBuilder
    private var compactionNotificationView: some View {
        let isInProgress = event.compactionIsInProgress
        let tokensBefore = event.compactionTokensBefore
        let tokensAfter = event.compactionTokensAfter
        let reason = event.compactionReason
        let summary = event.compactionSummary
        CompactionNotificationView(
            isInProgress: isInProgress,
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            reason: reason,
            onTap: isInProgress ? nil : {
                if let resourceId = event.contextControlActionResourceId {
                    onTap?(.contextControlAction(resourceId: resourceId))
                } else {
                    onTap?(.compaction(tokensBefore: tokensBefore, tokensAfter: tokensAfter, reason: reason, summary: summary, preservedTurns: event.compactionPreservedTurns, summarizedTurns: event.compactionSummarizedTurns))
                }
            }
        )
    }

    @ViewBuilder
    private var eventView: some View {
        switch event {
        case .modelChange(let from, let to):
            ModelChangeNotificationView(from: from, to: to)

        case .reasoningLevelChange(let from, let to):
            ReasoningLevelChangeNotificationView(from: from, to: to)

        case .interrupted:
            InterruptedNotificationView()

        case .contextCleared(let tokensBefore, let tokensAfter, let actionResourceId):
            ContextClearedNotificationView(
                tokensBefore: tokensBefore,
                tokensAfter: tokensAfter,
                onTap: actionResourceId.map { resourceId in
                    { onTap?(.contextControlAction(resourceId: resourceId)) }
                } ?? nil
            )

        case .messageDeleted(let targetType):
            MessageDeletedNotificationView(targetType: targetType)

        case .catchingUp:
            CatchingUpNotificationView()

        case .turnFailed(let error, let code, let recoverable, _):
            // C7: when the server marked the failure recoverable, surface a
            // "Retry" button that re-issues the last user prompt. Handler
            // lives in `ChatView.handleBubbleTap` → `retryLastTurn`.
            TurnFailedNotificationView(
                error: error,
                code: code,
                recoverable: recoverable,
                onRetry: recoverable ? { onTap?(.retryTurn) } : nil
            )

        case .providerError(let data):
            ProviderErrorNotificationView(
                data: data,
                onTap: {
                    onTap?(.providerError(data))
                }
            )

        case .compactionInProgress,
             .compaction:
            // Unreachable by construction — these cases are intercepted by
            // the parent `body`'s check on `isCompactionNotification` before
            // `eventView` is ever evaluated. We enumerate them explicitly so
            // the compiler flags any new `SystemEvent` case that lacks a
            // rendering here instead of silently rendering an empty pill.
            EmptyView()
        }
    }
}
