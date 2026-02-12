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
struct TaskManagerChipData: Equatable, Identifiable {
    var id: String { toolCallId }
    /// The tool call ID
    let toolCallId: String
    /// The action being performed (create, update, list, etc.)
    let action: String
    /// Task title from arguments (if available)
    let taskTitle: String?
    /// Short summary for chip display
    let chipSummary: String
    /// Full tool result text for detail sheet
    let fullResult: String?
    /// Raw tool arguments JSON for detail sheet
    let arguments: String
    /// Parsed entity snapshot from tool result (nil for list/search actions)
    let entityDetail: EntityDetail?
    /// Current status of the tool call
    var status: TaskManagerChipStatus = .completed
}

// MARK: - Entity Detail

/// Parsed entity snapshot from TaskManager tool result text.
/// Represents a historical snapshot of a task, project, or area at the time of the action.
struct EntityDetail: Equatable {
    enum EntityType: String, Equatable { case task, project, area }

    struct ListItem: Equatable {
        let mark: String      // "x", ">", " ", "b", "-"
        let id: String
        let title: String
        let extra: String?    // "[high]", etc.
    }

    struct ActivityItem: Equatable {
        let date: String
        let action: String
        let detail: String?
    }

    // Identity
    let entityType: EntityType
    let title: String
    let id: String
    let status: String

    // Task-specific
    let priority: String?
    let source: String?
    let activeForm: String?

    // Content
    let description: String?
    let notes: String?
    let tags: [String]

    // Relationships
    let projectName: String?    // "Auth Refactor (proj_abc)"
    let areaName: String?       // "Security (area_abc)"
    let parentId: String?

    // Time
    let dueDate: String?
    let deferredUntil: String?
    let estimatedMinutes: Int?
    let actualMinutes: Int?
    let createdAt: String?
    let updatedAt: String?
    let startedAt: String?
    let completedAt: String?

    // Counts (project/area)
    let taskCount: Int?
    let completedTaskCount: Int?
    let projectCount: Int?
    let activeTaskCount: Int?

    // Lists
    let subtasks: [ListItem]
    let tasks: [ListItem]        // for projects
    let blockedBy: [String]
    let blocks: [String]
    let activity: [ActivityItem]
}
