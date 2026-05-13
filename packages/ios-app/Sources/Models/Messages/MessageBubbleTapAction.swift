import Foundation

/// Unified tap action enum for MessageBubble callbacks.
/// Replaces 15 individual closure properties with a single `onTap` handler.
enum MessageBubbleTapAction {
    case skill(Skill)
    case askUserQuestion(AskUserQuestionToolData)
    case engineApproval(EngineApprovalToolData)
    case thinking(String)
    case compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String?, preservedTurns: Int?, summarizedTurns: Int?)
    case subagent(SubagentToolData)
    case notifyApp(NotifyAppChipData)
    case capabilityInvocation(CapabilityInvocationData)
    /// User tapped the cancel button on a running capability chip.
    /// Handler should call `agent.abortTool(invocationId:)` to cooperatively abort
    /// the in-flight invocation without aborting the rest of the turn.
    case cancelCapabilityInvocation(id: String)
    case subagentResult(sessionId: String)
    case subagentResultsReady(results: [SubagentResultEntry])
    case providerError(ProviderErrorDetailData)
    case memoryRetainDetail(title: String, summary: String?)
    /// User tapped a skill chip in the `skills.cleared` AskUser picker (M6).
    /// Handler should call `agent.activateSkill(skillName:)` to re-add the
    /// skill to the session's active set.
    case reactivateSkill(skillName: String)
    /// User tapped the "Retry" button on a `turn.failed` notification (C7).
    /// Handler re-issues the last user prompt so the agent tries the turn
    /// again. Only surfaced when the server marked the failure recoverable.
    case retryTurn
}
