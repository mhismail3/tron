import Foundation

// MARK: - TaskManager Types

/// Status of a TaskManager tool call
enum TaskManagerChipStatus: Equatable {
    /// Tool is running, no result yet
    case running
    /// Tool completed with result
    case completed
}

/// Data for rendering a TaskManager tool call as a compact chip
struct TaskManagerChipData: Equatable {
    /// The tool call ID
    let toolCallId: String
    /// The action being performed (create, update, list, etc.)
    let action: String
    /// Task title from arguments (if available)
    let taskTitle: String?
    /// First line of tool result (summary)
    let resultSummary: String?
    /// Current status of the tool call
    var status: TaskManagerChipStatus = .completed
}
