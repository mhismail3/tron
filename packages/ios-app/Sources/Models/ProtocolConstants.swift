import Foundation

/// Compaction trigger reasons from the server protocol.
enum CompactionReason: String, Sendable {
    case preTurnGuardrail = "pre_turn_guardrail"
    case thresholdExceeded = "threshold_exceeded"
    case manual

    /// Short display text for notification pills
    var displayText: String {
        switch self {
        case .preTurnGuardrail: "auto"
        case .thresholdExceeded: "threshold"
        case .manual: "manual"
        }
    }

    /// Display text for detail sheets (capitalized)
    var detailDisplayText: String {
        switch self {
        case .preTurnGuardrail: "Auto"
        case .thresholdExceeded: "Threshold"
        case .manual: "Manual"
        }
    }
}

/// Protocol string constants shared between iOS and the server.
enum AgentProtocol {
    /// Prefix for AskUserQuestion answer prompts
    static let askUserAnswerPrefix = "[Answers to your questions]"
    /// Prefix for subagent result prompts
    static let subagentResultPrefix = "[SUBAGENT RESULTS"
}
