import SwiftUI

/// Shared task status/priority color and mark helpers.
/// Replaces duplicate logic in EntitySnapshotCard and TaskDetailSheet.
enum TaskFormatting {

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "completed": return .tronSuccess
        case "in_progress": return .tronTeal
        case "cancelled": return .tronError
        case "backlog": return .tronSlate
        case "paused": return .tronAmber
        case "archived": return .tronSlate
        case "active": return .tronTeal
        case "pending": return .tronSlate
        default: return .tronSlate
        }
    }

    static func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "critical", "[critical]": return .tronError
        case "high", "[high]": return .orange
        case "low", "[low]": return .tronTextMuted
        default: return .tronTextSecondary
        }
    }

    static func statusMark(_ status: String) -> String {
        switch status {
        case "completed": return "x"
        case "in_progress": return ">"
        case "cancelled": return "-"
        case "backlog": return "b"
        default: return " "
        }
    }
}
