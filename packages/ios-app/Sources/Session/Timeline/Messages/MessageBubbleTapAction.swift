import Foundation

/// Unified tap action enum for MessageBubble callbacks.
/// Replaces 15 individual closure properties with a single `onTap` handler.
enum MessageBubbleTapAction {
    case thinking(String)
    case compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String?, preservedTurns: Int?, summarizedTurns: Int?)
    case contextControlAction(resourceId: String)
    case capabilityInvocation(CapabilityInvocationData)
    /// User tapped the cancel button on a running capability chip.
    /// Handler should call `agent.abortCapabilityInvocation(invocationId:)` to cooperatively abort
    /// the in-flight invocation without aborting the rest of the turn.
    case cancelCapabilityInvocation(id: String)
    case providerError(ProviderErrorDetailData)
    case localErrorDetail(title: String, message: String, suggestion: String?)
    /// User tapped the "Retry" button on a `turn.failed` notification (C7).
    /// Handler re-issues the last user prompt so the agent tries the turn
    /// again. Only surfaced when the server marked the failure recoverable.
    case retryTurn
}
