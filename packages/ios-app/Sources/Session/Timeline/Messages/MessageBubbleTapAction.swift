import Foundation

/// Unified tap action enum for MessageBubble callbacks.
/// Replaces 15 individual closure properties with a single `onTap` handler.
enum MessageBubbleTapAction {
    case thinking(String, kind: ThinkingDisplayKind)
    case compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String?, preservedTurns: Int?, summarizedTurns: Int?)
    case toolInvocation(ToolInvocationData)
    case toolInvocationGroup(ToolInvocationGroupData)
    case userInput(UserInputRequest)
    /// User tapped the cancel button on a running tool chip.
    /// Handler should call `agent.abortToolInvocation(invocationId:)` to cooperatively abort
    /// the in-flight invocation without aborting the rest of the turn.
    case cancelToolInvocation(id: String)
    case providerError(ProviderErrorDetailData)
    case localErrorDetail(title: String, message: String, suggestion: String?)
    /// User tapped the "Retry" button on a `turn.failed` notification (C7).
    /// Handler re-issues the last user prompt so the agent tries the turn
    /// again. Only surfaced when the server marked the failure recoverable.
    case retryTurn
}
