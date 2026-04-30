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
    /// A skill was deactivated from context
    case skillDeactivated(skillName: String)
    /// Active skills were cleared by compaction (M6).
    ///
    /// `mode` controls rendering:
    /// - `.clearAll`: informational banner listing the cleared skill names.
    ///   The user can re-add via `@skill-name` or the sidebar picker.
    /// - `.askUser`: interactive picker — each skill becomes a tappable chip
    ///   that re-activates it via the `skill.activate` RPC.
    case skillsCleared(clearedSkills: [String], mode: SkillsClearedMode)
    /// Rules were loaded on session start
    case rulesLoaded(count: Int)
    /// Dynamic scoped rules were activated by file access
    case rulesActivated(rules: [ActivatedRuleEntry], totalActivated: Int)
    /// Catching up to in-progress session
    case catchingUp
    /// Turn failed with error
    case turnFailed(error: String, code: String?, recoverable: Bool)
    /// Subagent completed while parent was idle - results available for review (individual, from persisted events)
    case subagentResultAvailable(subagentSessionId: String, taskPreview: String, success: Bool)
    /// Consolidated subagent results notification - groups multiple completed subagents into one notification
    case subagentResultsReady(results: [SubagentResultEntry])
    /// Provider API error (auth, rate limit, network, etc.)
    case providerError(ProviderErrorDetailData)
    /// Memory retain in progress (shows spinner pill)
    case memoryRetainInProgress
    /// Automatic memory retain in progress (shows distinct "Auto-retaining" pill)
    case memoryAutoRetainInProgress(intervalFired: Int)
    /// Automatic memory retain failed mid-pipeline (H3). Paired with a
    /// prior `memoryAutoRetainInProgress` — a `memoryUpdated` still
    /// lands afterward when the server writes the fallback summary.
    case memoryAutoRetainFailed(intervalFired: Int, reason: String)
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
        case .skillDeactivated:            return .tronCyan
        case .skillsCleared:              return .tronCyan
        case .rulesLoaded:                return .tronIndigo
        case .rulesActivated:             return .tronIndigo
        case .catchingUp:                 return .tronSlate
        case .turnFailed:                 return .tronError
        case .subagentResultAvailable(_, _, let success):
            return success ? .tronSuccess : .tronError
        case .subagentResultsReady(let results):
            return results.allSatisfy(\.success) ? .tronSuccess : .tronError
        case .providerError:              return .tronError
        case .memoryRetainInProgress:     return .tronPink
        case .memoryAutoRetainInProgress: return .tronPink
        case .memoryAutoRetainFailed:     return .tronError
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
        case .skillDeactivated(let skillName):
            return "\(skillName) deactivated from context"
        case .skillsCleared(let clearedSkills, let mode):
            let noun = clearedSkills.count == 1 ? "skill" : "skills"
            switch mode {
            case .clearAll:
                return "Cleared \(clearedSkills.count) \(noun) on compaction"
            case .askUser:
                return "Re-activate \(clearedSkills.count) \(noun)?"
            }
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
        case .subagentResultsReady(let results):
            if results.count == 1 {
                return results[0].success ? "Agent completed: \(results[0].taskPreview)" : "Agent failed: \(results[0].taskPreview)"
            }
            return "\(results.count) agent results ready"
        case .providerError(let data):
            let label = ErrorCategoryDisplay.label(for: data.category, provider: data.provider)
            return "\(label): \(data.message)"
        case .memoryRetainInProgress:
            return "Retaining memory..."
        case .memoryAutoRetainInProgress:
            return "Auto-retaining memory..."
        case .memoryAutoRetainFailed(_, let reason):
            return "Auto-retain failed: \(reason)"
        case .memoryRetained(let title, _):
            return "Memory saved: \(title)"
        case .memoryRetainedNothingNew:
            return "Nothing new to retain"
        }
    }

    /// Whether this is a memory retain notification (for unified animation)
    var isMemoryRetainNotification: Bool {
        switch self {
        case .memoryRetainInProgress, .memoryAutoRetainInProgress,
             .memoryAutoRetainFailed,
             .memoryRetained, .memoryRetainedNothingNew:
            return true
        default:
            return false
        }
    }

    /// Whether the memory retain is still in progress
    var memoryRetainIsInProgress: Bool {
        switch self {
        case .memoryRetainInProgress, .memoryAutoRetainInProgress: return true
        default: return false
        }
    }

    /// True for automatic retentions (policy-triggered), false for manual ones.
    /// Controls UI pill copy ("Auto-retaining memory..." vs "Retaining memory...").
    var memoryRetainIsAuto: Bool {
        if case .memoryAutoRetainInProgress = self { return true }
        if case .memoryAutoRetainFailed = self { return true }
        return false
    }

    /// When present, the memory-retain pill should render in its "failed"
    /// variant with this reason (H3). Nil for all other memory states.
    var memoryRetainFailureReason: String? {
        if case .memoryAutoRetainFailed(_, let reason) = self { return reason }
        return nil
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
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return level.capitalized
        }
    }
}

// MARK: - Subagent Result Entry

/// Lightweight entry for consolidated subagent result notifications.
/// Used by `SystemEvent.subagentResultsReady` to group multiple completed subagents.
struct SubagentResultEntry: Equatable, Hashable {
    let subagentSessionId: String
    let taskPreview: String
    let success: Bool
}
