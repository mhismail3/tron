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
    /// Parsed list result from tool result (nil for entity actions)
    var listResult: ListResult? = nil
    /// Duration in milliseconds (nil while running)
    var durationMs: Int? = nil
    /// Current status of the tool call
    var status: TaskManagerChipStatus = .completed

    /// Formatted duration for display
    var formattedDuration: String? {
        guard let ms = durationMs else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }
}

// MARK: - List Result

/// Parsed list/search result from TaskManager tool result text.
/// Used for list, search, list_projects, list_areas actions.
enum ListResult: Equatable {
    case tasks([TaskListItem])
    case searchResults([SearchResultItem])
    case projects([ProjectListItem])
    case areas([AreaListItem])
    case empty(String)  // "No tasks found." etc.
}

/// A task item in a list result: `[mark] id: title (P:priority, due:date)`
struct TaskListItem: Equatable, Identifiable {
    var id: String { taskId }
    let taskId: String
    let title: String
    let mark: String          // "x", ">", " ", "b", "-"
    let priority: String?     // "high", "critical", etc. (nil if medium)
    let dueDate: String?
}

/// A search result item: `  id: title [status]`
struct SearchResultItem: Equatable, Identifiable {
    var id: String { itemId }
    let itemId: String
    let title: String
    let status: String
}

/// A project item in a list result: `  id: title [status] (M/K tasks)`
struct ProjectListItem: Equatable, Identifiable {
    var id: String { projectId }
    let projectId: String
    let title: String
    let status: String
    let completedTasks: Int?
    let totalTasks: Int?
}

/// An area item in a list result: `  id: title [status] Np/Mt (K active)`
struct AreaListItem: Equatable, Identifiable {
    var id: String { areaId }
    let areaId: String
    let title: String
    let status: String
    let projectCount: Int?
    let taskCount: Int?
    let activeTaskCount: Int?
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
