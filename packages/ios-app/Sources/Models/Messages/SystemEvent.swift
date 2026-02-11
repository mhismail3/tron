import Foundation

// MARK: - System Event (Notifications)

/// System events are non-content notifications displayed in the chat
/// (model changes, context operations, status updates, etc.)
enum SystemEvent: Equatable {
    /// Model was switched during the session
    case modelChange(from: String, to: String)
    /// Reasoning level was changed
    case reasoningLevelChange(from: String, to: String)
    /// Session was interrupted
    case interrupted
    /// Voice transcription failed
    case transcriptionFailed
    /// No speech was detected in recording
    case transcriptionNoSpeech
    /// Context compaction started (in-progress spinner)
    case compactionInProgress(reason: String)
    /// Context was compacted to save tokens
    case compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String?)
    /// Context was cleared
    case contextCleared(tokensBefore: Int, tokensAfter: Int)
    /// A message was deleted from context
    case messageDeleted(targetType: String)
    /// A skill was removed from context
    case skillRemoved(skillName: String)
    /// Rules were loaded on session start
    case rulesLoaded(count: Int)
    /// Catching up to in-progress session
    case catchingUp
    /// Turn failed with error
    case turnFailed(error: String, code: String?, recoverable: Bool)
    /// Subagent completed while parent was idle - results available for review
    case subagentResultAvailable(subagentSessionId: String, taskPreview: String, success: Bool)
    /// Memory ledger write in progress (spinner)
    case memoryUpdating
    /// Memory ledger entry was written after a response cycle
    case memoryUpdated(title: String, entryType: String)
    /// Memories were auto-injected at session start
    case memoriesLoaded(count: Int)

    /// Human-readable description for the event
    var textContent: String {
        switch self {
        case .modelChange(let from, let to):
            return "Switched from \(from) to \(to)"
        case .reasoningLevelChange(let from, let to):
            return "Reasoning: \(SystemEvent.reasoningLabel(from)) → \(SystemEvent.reasoningLabel(to))"
        case .interrupted:
            return "Session interrupted"
        case .transcriptionFailed:
            return "Transcription failed"
        case .transcriptionNoSpeech:
            return "No speech detected"
        case .compactionInProgress:
            return "Compacting context..."
        case .compaction(let before, let after, _, _):
            let saved = before - after
            return "Context compacted: \(TokenFormatter.format(saved)) tokens saved"
        case .contextCleared(let before, let after):
            let freed = before - after
            return "Context cleared: \(TokenFormatter.format(freed)) tokens freed"
        case .messageDeleted(let targetType):
            let typeLabel = targetType == "message.user" ? "user message" :
                           targetType == "message.assistant" ? "assistant message" :
                           targetType == "tool.result" ? "tool result" : "message"
            return "Deleted \(typeLabel) from context"
        case .skillRemoved(let skillName):
            return "\(skillName) removed from context"
        case .rulesLoaded(let count):
            return "Loaded \(count) \(count == 1 ? "rule" : "rules")"
        case .catchingUp:
            return "Loading latest messages..."
        case .turnFailed(let error, _, _):
            return "Request failed: \(error)"
        case .subagentResultAvailable(_, let taskPreview, let success):
            return success ? "Agent completed: \(taskPreview)" : "Agent failed: \(taskPreview)"
        case .memoryUpdating:
            return "Retaining memory..."
        case .memoryUpdated(let title, _):
            return "Memory updated: \(title)"
        case .memoriesLoaded(let count):
            return "Loaded \(count) \(count == 1 ? "memory" : "memories")"
        }
    }

    private static func reasoningLabel(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return level.capitalized
        }
    }
}
