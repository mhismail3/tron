import Foundation
import SwiftUI

// MARK: - System Event (Notifications)

/// System events are non-content notifications displayed in the chat
/// (model changes, context operations, status updates, etc.)
enum SystemEvent: Equatable, Hashable {
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
    case compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String?, preservedTurns: Int?, summarizedTurns: Int?)
    /// Context was cleared
    case contextCleared(tokensBefore: Int, tokensAfter: Int)
    /// A message was deleted from context
    case messageDeleted(targetType: String)
    /// A skill was removed from context
    case skillRemoved(skillName: String)
    /// Rules were loaded on session start
    case rulesLoaded(count: Int)
    /// Dynamic scoped rules were activated by file access
    case rulesActivated(rules: [ActivatedRuleEntry], totalActivated: Int)
    /// Catching up to in-progress session
    case catchingUp
    /// Turn failed with error
    case turnFailed(error: String, code: String?, recoverable: Bool)
    /// Subagent completed while parent was idle - results available for review
    case subagentResultAvailable(subagentSessionId: String, taskPreview: String, success: Bool)
    /// Provider API error (auth, rate limit, network, etc.)
    case providerError(ProviderErrorDetailData)
    /// Memory retain in progress (shows spinner pill)
    case memoryRetainInProgress
    /// Memory was retained to long-term log
    case memoryRetained(title: String, summary: String?)
    /// Memory retain was requested but there was nothing new since the last boundary
    case memoryRetainedNothingNew

/// Tint color for the notification pill — single source of truth.
    var tintColor: Color {
        switch self {
        case .modelChange:                return .tronEmerald
        case .reasoningLevelChange:       return .tronEmerald
        case .interrupted:                return .tronError
        case .transcriptionFailed:        return .tronError
        case .transcriptionNoSpeech:      return .tronAmber
        case .compactionInProgress:       return .tronSky
        case .compaction:                 return .tronSky
        case .contextCleared:             return .tronSky
        case .messageDeleted:             return .tronSky
        case .skillRemoved:               return .tronCyan
        case .rulesLoaded:                return .tronIndigo
        case .rulesActivated:             return .tronIndigo
        case .catchingUp:                 return .tronSlate
        case .turnFailed:                 return .tronError
        case .subagentResultAvailable(_, _, let success):
            return success ? .tronSuccess : .tronError
        case .providerError:              return .tronError
        case .memoryRetainInProgress:     return .tronPink
        case .memoryRetained:             return .tronPink
        case .memoryRetainedNothingNew:   return .tronPink
        }
    }

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
        case .compaction(let before, let after, _, _, _, _):
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
        case .rulesActivated(let rules, _):
            return "Loaded \(rules.count) nested \(rules.count == 1 ? "rule" : "rules")"
        case .catchingUp:
            return "Loading latest messages..."
        case .turnFailed(let error, _, _):
            return "Request failed: \(error)"
        case .subagentResultAvailable(_, let taskPreview, let success):
            return success ? "Agent completed: \(taskPreview)" : "Agent failed: \(taskPreview)"
        case .providerError(let data):
            let label = ErrorCategoryDisplay.label(for: data.category, provider: data.provider)
            return "\(label): \(data.message)"
        case .memoryRetainInProgress:
            return "Retaining memory..."
        case .memoryRetained(let title, _):
            return "Memory saved: \(title)"
        case .memoryRetainedNothingNew:
            return "Nothing new to retain"
        }
    }

    /// Whether this is a memory retain notification (for unified animation)
    var isMemoryRetainNotification: Bool {
        switch self {
        case .memoryRetainInProgress, .memoryRetained, .memoryRetainedNothingNew: return true
        default: return false
        }
    }

    /// Whether the memory retain is still in progress
    var memoryRetainIsInProgress: Bool {
        if case .memoryRetainInProgress = self { return true }
        return false
    }

    /// Memory retain title (nil for in-progress / nothing-new)
    var memoryRetainTitle: String? {
        if case .memoryRetained(let title, _) = self { return title }
        return nil
    }

    /// Memory retain summary (nil for in-progress / nothing-new)
    var memoryRetainSummary: String? {
        if case .memoryRetained(_, let summary) = self { return summary }
        return nil
    }

    /// Whether this is a compaction in-progress or completed event (for unified animation)
    var isCompactionNotification: Bool {
        switch self {
        case .compactionInProgress, .compaction: return true
        default: return false
        }
    }

    /// Whether the compaction notification is still in progress
    var compactionIsInProgress: Bool {
        if case .compactionInProgress = self { return true }
        return false
    }

    /// Tokens before compaction (0 for in-progress)
    var compactionTokensBefore: Int {
        if case .compaction(let before, _, _, _, _, _) = self { return before }
        return 0
    }

    /// Tokens after compaction (0 for in-progress)
    var compactionTokensAfter: Int {
        if case .compaction(_, let after, _, _, _, _) = self { return after }
        return 0
    }

    /// Compaction reason
    var compactionReason: String {
        switch self {
        case .compactionInProgress(let reason): return reason
        case .compaction(_, _, let reason, _, _, _): return reason
        default: return ""
        }
    }

    /// Compaction summary (nil for in-progress)
    var compactionSummary: String? {
        if case .compaction(_, _, _, let summary, _, _) = self { return summary }
        return nil
    }

    /// Number of turns preserved during compaction
    var compactionPreservedTurns: Int? {
        if case .compaction(_, _, _, _, let preserved, _) = self { return preserved }
        return nil
    }

    /// Number of turns summarized during compaction
    var compactionSummarizedTurns: Int? {
        if case .compaction(_, _, _, _, _, let summarized) = self { return summarized }
        return nil
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
