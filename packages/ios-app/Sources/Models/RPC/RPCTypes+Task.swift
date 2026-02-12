import Foundation

// MARK: - Task Types

/// Task item returned from server (matches agent Task interface)
struct RpcTask: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let description: String?
    let activeForm: String?
    let notes: String?
    let status: TaskStatus
    let priority: TaskPriority
    let source: TaskSource
    let tags: [String]
    let projectId: String?
    let parentTaskId: String?
    let areaId: String?
    let workspaceId: String?
    let dueDate: String?
    let deferredUntil: String?
    let startedAt: String?
    let completedAt: String?
    let createdAt: String
    let updatedAt: String
    let estimatedMinutes: Int?
    let actualMinutes: Int?
    let createdBySessionId: String?
    let lastSessionId: String?
    let lastSessionAt: String?
    let sortOrder: Int?
    let metadata: [String: AnyCodable]?

    /// Status of a task
    enum TaskStatus: String, Decodable, CaseIterable {
        case backlog
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled

        var displayName: String {
            switch self {
            case .backlog: return "Backlog"
            case .pending: return "Pending"
            case .inProgress: return "In Progress"
            case .completed: return "Completed"
            case .cancelled: return "Cancelled"
            }
        }

        var icon: String {
            switch self {
            case .backlog: return "tray"
            case .pending: return "circle"
            case .inProgress: return "circle.fill"
            case .completed: return "checkmark.circle.fill"
            case .cancelled: return "xmark.circle.fill"
            }
        }
    }

    /// Priority of a task
    enum TaskPriority: String, Decodable {
        case low
        case medium
        case high
        case critical

        var displayName: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .critical: return "Critical"
            }
        }
    }

    /// Source of a task
    enum TaskSource: String, Decodable {
        case agent
        case user
        case skill
        case system

        var displayName: String {
            switch self {
            case .agent: return "Agent"
            case .user: return "User"
            case .skill: return "Skill"
            case .system: return "System"
            }
        }
    }

    /// Format the createdAt timestamp for display (short format like "1m", "5h")
    var formattedCreatedAt: String {
        formatShortRelativeTime(createdAt)
    }

    /// Format the completedAt timestamp for display
    var formattedCompletedAt: String? {
        guard let completedAt else { return nil }
        return formatShortRelativeTime(completedAt)
    }

    // Hashable conformance (ignore metadata for equality)
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: RpcTask, rhs: RpcTask) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.status == rhs.status &&
        lhs.priority == rhs.priority &&
        lhs.updatedAt == rhs.updatedAt
    }
}

// MARK: - RPC Parameters & Results

/// Parameters for tasks.list
struct TaskListParams: Encodable {
    let status: String?
    let limit: Int?

    init(status: String? = nil, limit: Int? = nil) {
        self.status = status
        self.limit = limit
    }
}

/// Result of tasks.list
struct TaskListResult: Decodable {
    let tasks: [RpcTask]
    let total: Int
}

/// Parameters for tasks.get
struct TaskGetParams: Encodable {
    let taskId: String
}

// MARK: - Area Types

/// Area of responsibility (PARA model — ongoing concerns)
struct RpcArea: Decodable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let status: AreaStatus
    let tags: [String]
    let projectCount: Int?
    let taskCount: Int?
    let activeTaskCount: Int?
    let createdAt: String
    let updatedAt: String

    enum AreaStatus: String, Decodable {
        case active
        case archived

        var displayName: String {
            switch self {
            case .active: return "Active"
            case .archived: return "Archived"
            }
        }
    }
}

/// Parameters for areas.list
struct AreaListParams: Encodable {
    let status: String?
    let limit: Int?

    init(status: String? = nil, limit: Int? = nil) {
        self.status = status
        self.limit = limit
    }
}

/// Result of areas.list
struct AreaListResult: Decodable {
    let areas: [RpcArea]
    let total: Int
}

// MARK: - Short Relative Time Formatting

/// Format as short relative time (e.g., "1m", "5h", "2d")
/// Uses static calculation to avoid constant re-renders
func formatShortRelativeTime(_ isoString: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = formatter.date(from: isoString)
    if date == nil {
        formatter.formatOptions = [.withInternetDateTime]
        date = formatter.date(from: isoString)
    }
    guard let date else { return "" }

    let now = Date()
    let seconds = Int(now.timeIntervalSince(date))

    if seconds < 60 {
        return "now"
    } else if seconds < 3600 {
        let minutes = seconds / 60
        return "\(minutes)m"
    } else if seconds < 86400 {
        let hours = seconds / 3600
        return "\(hours)h"
    } else {
        let days = seconds / 86400
        return "\(days)d"
    }
}
