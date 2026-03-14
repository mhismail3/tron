import Foundation

/// Unified tap action enum for MessageBubble callbacks.
/// Replaces 15 individual closure properties with a single `onTap` handler.
enum MessageBubbleTapAction {
    case skill(Skill)
    case spell(Skill)
    case askUserQuestion(AskUserQuestionToolData)
    case thinking(String)
    case compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String?, preservedTurns: Int?, summarizedTurns: Int?)
    case subagent(SubagentToolData)
    case renderAppUI(RenderAppUIChipData)
    case taskManager(TaskManagerChipData)
    case notifyApp(NotifyAppChipData)
    case commandTool(CommandToolChipData)
    case queryAgent(QueryAgentChipData)
    case waitForAgents(WaitForAgentsChipData)
    case memoryUpdated(title: String, entryType: String, eventId: String?)
    case subagentResult(sessionId: String)
    case providerError(ProviderErrorDetailData)
}
