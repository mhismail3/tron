import Foundation
import SwiftUI

// MARK: - TaskManager Types

/// Status of a TaskManager tool call
enum TaskManagerChipStatus: Equatable {
    /// Tool is running, no result yet
    case running
    /// Tool completed with result
    case completed

    var label: String {
        switch self {
        case .running: "Running"
        case .completed: "Completed"
        }
    }

    var iconName: String {
        switch self {
        case .running: ""
        case .completed: "checklist"
        }
    }
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
    /// Parsed entity snapshot from tool result (nil for list/search/batch actions)
    let entityDetail: EntityDetail?
    /// Parsed list result from tool result (nil for entity/batch actions)
    var listResult: ListResult? = nil
    /// Parsed batch result from tool result (nil for non-batch actions)
    var batchResult: BatchResult? = nil
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
enum ListResult: Equatable {
    case tasks([TaskListItem])
    case searchResults([SearchResultItem])
    case empty(String)  // "No tasks found." etc.
}

/// A task item in a list result
struct TaskListItem: Equatable, Identifiable {
    var id: String { taskId }
    let taskId: String
    let title: String
    let mark: String          // "x", ">", " ", "-", "?"
    let status: String?
}

/// A search result item
struct SearchResultItem: Equatable, Identifiable {
    var id: String { itemId }
    let itemId: String
    let title: String
    let status: String
}

// MARK: - Batch Result

/// Parsed result from batch_create actions.
struct BatchResult: Equatable {
    let affected: Int
    /// Created task IDs (batch_create only)
    let ids: [String]
}

// MARK: - Entity Detail

/// Parsed entity snapshot from TaskManager tool result text.
/// Represents a historical snapshot of a task at the time of the action.
struct EntityDetail: Equatable {
    struct ListItem: Equatable {
        let mark: String      // "x", ">", " ", "-", "?"
        let id: String
        let title: String
        let extra: String?
    }

    struct ActivityItem: Equatable {
        let date: String
        let action: String
        let detail: String?
    }

    // Identity
    let title: String
    let id: String
    let status: String

    // Task-specific
    let activeForm: String?

    // Content
    let description: String?
    let notes: String?

    // Relationships
    let parentId: String?

    // Time
    let createdAt: String?
    let updatedAt: String?
    let startedAt: String?
    let completedAt: String?

    // Lists
    let subtasks: [ListItem]
    let activity: [ActivityItem]
}
