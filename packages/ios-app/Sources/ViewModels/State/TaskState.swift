import SwiftUI

/// Manages task state for ChatViewModel
/// Tracks persistent tasks from the task manager system
@Observable
@MainActor
final class TaskState {
    // MARK: - Tasks

    /// Current tasks from server
    private(set) var tasks: [RpcTask] = []

    /// Whether the task sheet is displayed
    var showSheet = false

    /// Loading state for initial fetch
    var isLoading = false

    /// Error message if fetch failed
    var errorMessage: String?

    init() {}

    // MARK: - Computed Properties

    /// Count of incomplete tasks (not completed or cancelled)
    var incompleteCount: Int {
        tasks.filter { $0.status != .completed && $0.status != .cancelled }.count
    }

    /// Whether there are any tasks
    var hasTasks: Bool {
        !tasks.isEmpty
    }

    /// Tasks grouped by status for display
    var inProgressTasks: [RpcTask] {
        tasks.filter { $0.status == .inProgress }
    }

    var pendingTasks: [RpcTask] {
        tasks.filter { $0.status == .pending }
    }

    var backlogTasks: [RpcTask] {
        tasks.filter { $0.status == .backlog }
    }

    var completedTasks: [RpcTask] {
        tasks.filter { $0.status == .completed }
    }

    var cancelledTasks: [RpcTask] {
        tasks.filter { $0.status == .cancelled }
    }

    /// Summary string for display
    var displaySummary: String {
        if tasks.isEmpty {
            return "No tasks"
        }

        var parts: [String] = []
        let ip = inProgressTasks.count
        let p = pendingTasks.count
        let c = completedTasks.count

        if ip > 0 { parts.append("\(ip) in progress") }
        if p > 0 { parts.append("\(p) pending") }
        if c > 0 { parts.append("\(c) completed") }

        return parts.joined(separator: ", ")
    }

    // MARK: - Updates from Server

    /// Update tasks from server (via RPC or after WebSocket event)
    func updateTasks(_ newTasks: [RpcTask]) {
        withAnimation(.easeInOut(duration: 0.2)) {
            self.tasks = newTasks
            self.isLoading = false
            self.errorMessage = nil
        }
    }

    /// Remove a single task by ID (for delete events)
    func removeTask(id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            self.tasks.removeAll { $0.id == id }
        }
    }

    // MARK: - Loading States

    /// Start loading tasks
    func startLoading() {
        isLoading = true
        errorMessage = nil
    }

    /// Handle load error
    func setError(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    // MARK: - UI Actions

    /// Show the task sheet
    func show() {
        showSheet = true
    }

    /// Dismiss the task sheet
    func dismiss() {
        showSheet = false
    }

    // MARK: - Cleanup

    /// Clear all state (for new session)
    func clearAll() {
        tasks.removeAll()
        isLoading = false
        errorMessage = nil
        showSheet = false
    }
}
