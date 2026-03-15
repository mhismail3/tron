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
    let parentTaskId: String?
    let startedAt: String?
    let completedAt: String?
    let createdAt: String
    let updatedAt: String
    let createdBySessionId: String?
    let lastSessionId: String?
    let lastSessionAt: String?
    let metadata: [String: AnyCodable]?

    /// Status of a task
    enum TaskStatus: String, Decodable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled
        case stale

        var displayName: String {
            switch self {
            case .pending: return "Pending"
            case .inProgress: return "In Progress"
            case .completed: return "Completed"
            case .cancelled: return "Cancelled"
            case .stale: return "Stale"
            }
        }

        var icon: String {
            switch self {
            case .pending: return "circle"
            case .inProgress: return "circle.fill"
            case .completed: return "checkmark.circle.fill"
            case .cancelled: return "xmark.circle.fill"
            case .stale: return "exclamationmark.circle"
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

// MARK: - Short Relative Time Formatting

/// Format as short relative time (e.g., "1m", "5h", "2d")
/// Uses static calculation to avoid constant re-renders
func formatShortRelativeTime(_ isoString: String) -> String {
    guard let date = DateParser.parse(isoString) else { return "" }

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
