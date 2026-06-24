import SwiftUI

/// Shared task status color and mark helpers.
enum TaskFormatting {

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "completed": return .tronSuccess
        case "in_progress": return .tronTeal
        case "cancelled": return .tronError
        case "stale": return .tronAmber
        case "pending": return .tronSlate
        default: return .tronSlate
        }
    }

    static func statusMark(_ status: String) -> String {
        switch status {
        case "completed": return "x"
        case "in_progress": return ">"
        case "cancelled": return "-"
        case "stale": return "?"
        default: return " "
        }
    }
}
