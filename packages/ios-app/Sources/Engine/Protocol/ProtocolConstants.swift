import Foundation

/// Compaction trigger reasons from the server protocol.
enum CompactionReason: String, Sendable {
    case thresholdExceeded = "threshold_exceeded"
    case progressSignal = "progress_signal"
    case manual

    /// Short display text for notification pills
    var displayText: String {
        switch self {
        case .thresholdExceeded: "threshold"
        case .progressSignal: "progress"
        case .manual: "manual"
        }
    }

    /// Display text for detail sheets (capitalized)
    var detailDisplayText: String {
        switch self {
        case .thresholdExceeded: "Threshold"
        case .progressSignal: "Progress Signal"
        case .manual: "Manual"
        }
    }
}

