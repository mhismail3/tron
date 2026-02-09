import Foundation

// MARK: - Subagent Types

/// Status for a spawned subagent
enum SubagentStatus: String, Codable, Equatable {
    case running
    case completed
    case failed
}

/// Tracks whether completed results need user action
/// Used for non-blocking subagents that complete while the parent is idle
enum SubagentResultDeliveryStatus: String, Codable, Equatable {
    /// Parent was processing when subagent completed (results auto-injected)
    case notApplicable
    /// Completed while parent idle, awaiting user action to send results
    case pending
    /// User sent results to agent
    case sent
    /// User dismissed without sending
    case dismissed
}

/// Data for tracking a spawned subagent (rendered as a chip in chat)
struct SubagentToolData: Equatable {
    /// The tool call ID from SpawnSubagent
    let toolCallId: String
    /// Session ID of the spawned subagent
    let subagentSessionId: String
    /// The task assigned to the subagent
    let task: String
    /// Model used by the subagent
    var model: String?
    /// Current status
    var status: SubagentStatus
    /// Current turn number (while running)
    var currentTurn: Int
    /// Result summary (when completed)
    var resultSummary: String?
    /// Full output (when completed)
    var fullOutput: String?
    /// Duration in milliseconds
    var duration: Int?
    /// Error message (when failed)
    var error: String?
    /// Token usage (when completed)
    var tokenUsage: TokenUsage?
    /// Whether this subagent was spawned in blocking mode (parent waits for result via tool result)
    var blocking: Bool = false
    /// Tracks whether results need user action (for non-blocking subagents that complete while parent idle)
    var resultDeliveryStatus: SubagentResultDeliveryStatus = .notApplicable

    /// Formatted duration for display
    var formattedDuration: String? {
        guard let ms = duration else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }

    /// Short task preview for chip display
    var taskPreview: String {
        if task.count > 40 {
            return String(task.prefix(40)) + "..."
        }
        return task
    }
}
