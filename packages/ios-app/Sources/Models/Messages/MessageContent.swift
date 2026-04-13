import Foundation

// MARK: - Message Content

enum MessageContent: Equatable {
    // Core content types
    case text(String)
    case streaming(String)
    case thinking(visible: String, isExpanded: Bool, isStreaming: Bool)
    case toolUse(ToolUseData)
    case toolResult(ToolResultData)
    case error(String)
    case images([ImageContent])
    case attachments([Attachment])

    // System events (notifications) - consolidated
    case systemEvent(SystemEvent)

    // Special tool invocations (rendered as interactive chips)
    case askUserQuestion(AskUserQuestionToolData)
    case getConfirmation(GetConfirmationToolData)
    case answeredQuestions(questionCount: Int)
    case confirmedAction(approved: Bool)
    case subagentResultsDelivered(subagentCount: Int)
    case subagent(SubagentToolData)

    // MARK: - Convenience Factories (forward to systemEvent)
    // These provide cleaner API for common system event patterns

    /// In-chat notification for model change
    static func modelChange(from: String, to: String) -> MessageContent {
        .systemEvent(.modelChange(from: from, to: to))
    }
    /// In-chat notification for reasoning level change
    static func reasoningLevelChange(from: String, to: String) -> MessageContent {
        .systemEvent(.reasoningLevelChange(from: from, to: to))
    }
    /// In-chat notification for interrupted session
    static var interrupted: MessageContent {
        .systemEvent(.interrupted)
    }
    /// In-chat notification for transcription failure
    static var transcriptionFailed: MessageContent {
        .systemEvent(.transcriptionFailed)
    }
    /// In-chat notification for no speech detected
    static var transcriptionNoSpeech: MessageContent {
        .systemEvent(.transcriptionNoSpeech)
    }
    /// In-chat notification for compaction in progress
    static func compactionInProgress(reason: String) -> MessageContent {
        .systemEvent(.compactionInProgress(reason: reason))
    }
    /// In-chat notification for context compaction
    static func compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String?, preservedTurns: Int? = nil, summarizedTurns: Int? = nil) -> MessageContent {
        .systemEvent(.compaction(tokensBefore: tokensBefore, tokensAfter: tokensAfter, reason: reason, summary: summary, preservedTurns: preservedTurns, summarizedTurns: summarizedTurns))
    }
    /// In-chat notification for context clearing
    static func contextCleared(tokensBefore: Int, tokensAfter: Int) -> MessageContent {
        .systemEvent(.contextCleared(tokensBefore: tokensBefore, tokensAfter: tokensAfter))
    }
    /// In-chat notification for message deletion from context
    static func messageDeleted(targetType: String) -> MessageContent {
        .systemEvent(.messageDeleted(targetType: targetType))
    }
    /// In-chat notification for skill deactivation from context
    static func skillDeactivated(skillName: String) -> MessageContent {
        .systemEvent(.skillDeactivated(skillName: skillName))
    }
    /// In-chat notification for memory retain in progress
    static var memoryRetainInProgress: MessageContent {
        .systemEvent(.memoryRetainInProgress)
    }
    /// In-chat notification for memory retained to long-term log
    static func memoryRetained(title: String, summary: String?) -> MessageContent {
        .systemEvent(.memoryRetained(title: title, summary: summary))
    }
    /// In-chat notification for memory retain with nothing new
    static var memoryRetainedNothingNew: MessageContent {
        .systemEvent(.memoryRetainedNothingNew)
    }
    /// In-chat notification for rules loaded on session start
    static func rulesLoaded(count: Int) -> MessageContent {
        .systemEvent(.rulesLoaded(count: count))
    }
    /// In-chat notification for dynamically activated rules
    static func rulesActivated(rules: [ActivatedRuleEntry], totalActivated: Int) -> MessageContent {
        .systemEvent(.rulesActivated(rules: rules, totalActivated: totalActivated))
    }
    /// In-chat notification for catching up to in-progress session
    static var catchingUp: MessageContent {
        .systemEvent(.catchingUp)
    }
    /// In-chat notification for turn failure
    static func turnFailed(error: String, code: String?, recoverable: Bool) -> MessageContent {
        .systemEvent(.turnFailed(error: error, code: code, recoverable: recoverable))
    }
    /// In-chat notification for provider API errors
    static func providerError(_ data: ProviderErrorDetailData) -> MessageContent {
        .systemEvent(.providerError(data))
    }

    var textContent: String {
        switch self {
        case .text(let text), .streaming(let text):
            return text
        case .thinking(let visible, _, _):
            return visible
        case .toolUse(let tool):
            return "[\(tool.toolName)]"
        case .toolResult(let result):
            return result.content
        case .error(let message):
            return message
        case .images:
            return "[Images]"
        case .attachments(let files):
            let count = files.count
            return "[\(count) \(count == 1 ? "attachment" : "attachments")]"
        case .systemEvent(let event):
            return event.textContent
        case .askUserQuestion(let data):
            return "[\(data.params.questions.count) questions]"
        case .getConfirmation(let data):
            return data.params.action
        case .answeredQuestions(let count):
            return "Answered \(count) \(count == 1 ? "question" : "questions")"
        case .confirmedAction(let approved):
            return approved ? "Approved" : "Denied"
        case .subagentResultsDelivered(let count):
            return count == 1
                ? "Sent sub-agent result"
                : "Sent \(count) sub-agent results"
        case .subagent(let data):
            switch data.status {
            case .running:
                return "Subagent running (turn \(data.currentTurn))"
            case .completed:
                return data.resultSummary ?? "Subagent completed"
            case .failed:
                return data.error ?? "Subagent failed"
            }
        }
    }

    var isToolRelated: Bool {
        switch self {
        case .toolUse, .toolResult:
            return true
        default:
            return false
        }
    }

    var isNotification: Bool {
        if case .systemEvent = self {
            return true
        }
        return false
    }

    var isAskUserQuestion: Bool {
        if case .askUserQuestion = self {
            return true
        }
        return false
    }

    var isGetConfirmation: Bool {
        if case .getConfirmation = self {
            return true
        }
        return false
    }

    /// Extract SystemEvent if this is a system notification
    var asSystemEvent: SystemEvent? {
        if case .systemEvent(let event) = self {
            return event
        }
        return nil
    }
}
