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
    case subagentResult(sessionId: String)
    case subagentResultsReady(results: [SubagentResultEntry])
    case providerError(ProviderErrorDetailData)
    case memoryRetainDetail(title: String, summary: String?)
}
