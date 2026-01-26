import Foundation

// MARK: - Todo Methods

/// Todo item returned from server
struct RpcTodoItem: Decodable, Identifiable, Hashable {
    let id: String
    let content: String
    let activeForm: String
    let status: TodoStatus
    let source: TodoSource
    let createdAt: String
    let completedAt: String?
    let metadata: [String: AnyCodable]?

    /// Status of a todo item
    enum TodoStatus: String, Decodable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case completed

        var displayName: String {
            switch self {
            case .pending: return "Pending"
            case .inProgress: return "In Progress"
            case .completed: return "Completed"
            }
        }

        var icon: String {
            switch self {
            case .pending: return "circle"
            case .inProgress: return "circle.fill"
            case .completed: return "checkmark.circle.fill"
            }
        }
    }

    /// Source of a todo item
    enum TodoSource: String, Decodable {
        case agent
        case user
        case skill

        var displayName: String {
            switch self {
            case .agent: return "Agent"
            case .user: return "User"
            case .skill: return "Skill"
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

    /// Format as short relative time (e.g., "1m", "5h", "2d")
    /// Uses static calculation to avoid constant re-renders
    private func formatShortRelativeTime(_ isoString: String) -> String {
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

    // Hashable conformance (ignore metadata for equality)
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: RpcTodoItem, rhs: RpcTodoItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.content == rhs.content &&
        lhs.activeForm == rhs.activeForm &&
        lhs.status == rhs.status &&
        lhs.source == rhs.source
    }
}

/// Backlogged task from a previous session
struct RpcBackloggedTask: Decodable, Identifiable, Hashable {
    let id: String
    let content: String
    let activeForm: String
    let status: RpcTodoItem.TodoStatus
    let source: RpcTodoItem.TodoSource
    let createdAt: String
    let completedAt: String?
    let metadata: [String: AnyCodable]?
    let backloggedAt: String
    let backlogReason: BacklogReason
    let sourceSessionId: String
    let workspaceId: String
    let restoredToSessionId: String?
    let restoredAt: String?

    enum BacklogReason: String, Decodable {
        case sessionClear = "session_clear"
        case contextCompact = "context_compact"
        case sessionEnd = "session_end"

        var displayName: String {
            switch self {
            case .sessionClear: return "Session Cleared"
            case .contextCompact: return "Context Compacted"
            case .sessionEnd: return "Session Ended"
            }
        }
    }

    /// Whether this task has been restored to another session
    var isRestored: Bool { restoredToSessionId != nil }

    /// Format the backloggedAt timestamp for display (short format)
    var formattedBackloggedAt: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: backloggedAt)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: backloggedAt)
        }
        guard let date else { return "" }

        let now = Date()
        let seconds = Int(now.timeIntervalSince(date))

        if seconds < 60 {
            return "now"
        } else if seconds < 3600 {
            return "\(seconds / 60)m"
        } else if seconds < 86400 {
            return "\(seconds / 3600)h"
        } else {
            return "\(seconds / 86400)d"
        }
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: RpcBackloggedTask, rhs: RpcBackloggedTask) -> Bool {
        lhs.id == rhs.id
    }
}

/// Parameters for todo.list
struct TodoListParams: Encodable {
    let sessionId: String
}

/// Result of todo.list
struct TodoListResult: Decodable {
    let todos: [RpcTodoItem]
    let summary: String
}

/// Parameters for todo.getBacklog
struct TodoGetBacklogParams: Encodable {
    let workspaceId: String
    let includeRestored: Bool?
    let limit: Int?

    init(workspaceId: String, includeRestored: Bool? = nil, limit: Int? = nil) {
        self.workspaceId = workspaceId
        self.includeRestored = includeRestored
        self.limit = limit
    }
}

/// Result of todo.getBacklog
struct TodoGetBacklogResult: Decodable {
    let tasks: [RpcBackloggedTask]
    let totalCount: Int
}

/// Parameters for todo.restore
struct TodoRestoreParams: Encodable {
    let sessionId: String
    let taskIds: [String]
}

/// Result of todo.restore
struct TodoRestoreResult: Decodable {
    let restoredTodos: [RpcTodoItem]
    let restoredCount: Int
}

/// Parameters for todo.getBacklogCount
struct TodoGetBacklogCountParams: Encodable {
    let workspaceId: String
}

/// Result of todo.getBacklogCount
struct TodoGetBacklogCountResult: Decodable {
    let count: Int
}
