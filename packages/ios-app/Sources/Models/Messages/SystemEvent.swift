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
    /// Context compaction started (in-progress spinner)
    case compactionInProgress(reason: String)
    /// Context was compacted to save tokens
    case compaction(tokensBefore: Int, tokensAfter: Int, reason: String, summary: String?, preservedTurns: Int?, summarizedTurns: Int?)
    /// Context was cleared
    case contextCleared(tokensBefore: Int, tokensAfter: Int)
    /// A message was deleted from context
    case messageDeleted(targetType: String)
    /// Catching up to in-progress session
    case catchingUp
    /// Turn failed with error
    case turnFailed(error: String, code: String?, recoverable: Bool)
    /// Provider API error (auth, rate limit, network, etc.)
    case providerError(ProviderErrorDetailData)
/// Tint color for the notification pill — single source of truth.
    var tintColor: Color {
        switch self {
        case .modelChange:                return .tronEmerald
        case .reasoningLevelChange:       return .tronEmerald
        case .interrupted:                return .tronError
        case .compactionInProgress:       return .tronSky
        case .compaction:                 return .tronSky
        case .contextCleared:             return .tronSky
        case .messageDeleted:             return .tronSky
        case .catchingUp:                 return .tronSlate
        case .turnFailed:                 return .tronError
        case .providerError:              return .tronError
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
                           targetType == "capability.invocation.completed" ? "capability result" : "message"
            return "Deleted \(typeLabel) from context"
        case .catchingUp:
            return "Loading latest messages..."
        case .turnFailed(let error, _, _):
            return "Request failed: \(error)"
        case .providerError(let data):
            let label = ErrorCategoryDisplay.label(for: data.category, provider: data.provider)
            return "\(label): \(data.message)"
        }
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
