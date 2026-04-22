import Foundation

/// Unified tap action enum for MessageBubble callbacks.
/// Replaces 15 individual closure properties with a single `onTap` handler.
enum MessageBubbleTapAction {
    case skill(Skill)
    case askUserQuestion(AskUserQuestionToolData)
    case getConfirmation(GetConfirmationToolData)
    case thinking(String)
    case compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String?, preservedTurns: Int?, summarizedTurns: Int?)
    case subagent(SubagentToolData)
    case notifyApp(NotifyAppChipData)
    case commandTool(CommandToolChipData)
    /// User tapped the cancel button on a running command-tool chip.
    /// Handler should call `agent.abortTool(toolCallId:)` to cooperatively abort
    /// the in-flight tool without aborting the rest of the turn.
    case cancelCommandTool(toolCallId: String)
    case subagentResult(sessionId: String)
    case subagentResultsReady(results: [SubagentResultEntry])
    case providerError(ProviderErrorDetailData)
    case memoryRetainDetail(title: String, summary: String?)
    /// User tapped a skill chip in the `skills.cleared` AskUser picker (M6).
    /// Handler should call `agent.activateSkill(skillName:)` to re-add the
    /// skill to the session's active set.
    case reactivateSkill(skillName: String)
}
