import Foundation

// MARK: - TodoWrite Types

/// Status of a TodoWrite tool call
enum TodoWriteStatus: Equatable {
    /// Tool is running, no result yet
    case updating
    /// Tool completed with result
    case updated
}

/// Data for rendering a TodoWrite tool call as a compact chip
struct TodoWriteChipData: Equatable {
    /// The tool call ID from TodoWrite
    let toolCallId: String
    /// Count of new tasks (pending + in_progress)
    let newCount: Int
    /// Count of completed tasks
    let doneCount: Int
    /// Total count of tasks
    let totalCount: Int
    /// Current status of the tool call
    var status: TodoWriteStatus = .updated
}
