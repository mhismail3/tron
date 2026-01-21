import SwiftUI

/// Manages todo state for ChatViewModel
/// Extracted from ChatViewModel to reduce property sprawl
/// Tracks both session todos and workspace backlog
@Observable
@MainActor
final class TodoState {
    // MARK: - Session Todos

    /// Current todos for active session (from server)
    private(set) var todos: [RpcTodoItem] = []

    /// Summary string from server (e.g., "3 pending, 1 in progress")
    private(set) var summary: String = ""

    /// Whether the todo sheet is displayed
    var showSheet = false

    /// Loading state for initial fetch
    var isLoading = false

    /// Error message if fetch failed
    var errorMessage: String?

    // MARK: - Backlog

    /// Backlogged tasks from previous sessions
    private(set) var backlogTasks: [RpcBackloggedTask] = []

    /// Whether backlog section is expanded in UI
    var isBacklogExpanded = false

    /// Loading state for backlog fetch
    var isBacklogLoading = false

    /// Task IDs that are pending restore (for optimistic UI)
    private var pendingRestoreIds: Set<String> = []

    init() {}

    // MARK: - Computed Properties

    /// Count of incomplete tasks (pending + in progress)
    var incompleteCount: Int {
        todos.filter { $0.status != .completed }.count
    }

    /// Count of pending tasks
    var pendingCount: Int {
        todos.filter { $0.status == .pending }.count
    }

    /// Count of in-progress tasks
    var inProgressCount: Int {
        todos.filter { $0.status == .inProgress }.count
    }

    /// Count of completed tasks
    var completedCount: Int {
        todos.filter { $0.status == .completed }.count
    }

    /// Whether there are any todos
    var hasTodos: Bool {
        !todos.isEmpty
    }

    /// Todos grouped by status for display
    var inProgressTodos: [RpcTodoItem] {
        todos.filter { $0.status == .inProgress }
    }

    var pendingTodos: [RpcTodoItem] {
        todos.filter { $0.status == .pending }
    }

    var completedTodos: [RpcTodoItem] {
        todos.filter { $0.status == .completed }
    }

    /// Backlog tasks that haven't been restored (excluding pending restores)
    var displayedBacklogTasks: [RpcBackloggedTask] {
        backlogTasks.filter { !$0.isRestored && !pendingRestoreIds.contains($0.id) }
    }

    /// Count of unrestored backlog tasks
    var backlogCount: Int {
        displayedBacklogTasks.count
    }

    /// Summary string for display (formatted)
    var displaySummary: String {
        if todos.isEmpty {
            return "No tasks"
        }

        var parts: [String] = []
        if inProgressCount > 0 {
            parts.append("\(inProgressCount) in progress")
        }
        if pendingCount > 0 {
            parts.append("\(pendingCount) pending")
        }
        if completedCount > 0 {
            parts.append("\(completedCount) completed")
        }

        return parts.joined(separator: ", ")
    }

    // MARK: - Updates from Server

    /// Update todos from server (via RPC or WebSocket event)
    func updateTodos(_ newTodos: [RpcTodoItem], summary: String? = nil) {
        withAnimation(.easeInOut(duration: 0.2)) {
            self.todos = newTodos
            if let summary {
                self.summary = summary
            }
            self.isLoading = false
            self.errorMessage = nil
        }
    }

    /// Update todos from WebSocket event
    func handleTodosUpdated(_ event: TodosUpdatedEvent) {
        updateTodos(event.todos)
    }

    /// Update backlog from server
    func updateBacklog(_ tasks: [RpcBackloggedTask]) {
        withAnimation(.easeInOut(duration: 0.2)) {
            self.backlogTasks = tasks
            self.isBacklogLoading = false
        }
    }

    // MARK: - Optimistic Updates

    /// Mark task IDs as pending restore (optimistic UI)
    func markPendingRestore(_ taskIds: [String]) {
        pendingRestoreIds.formUnion(taskIds)
    }

    /// Clear pending restore state for task IDs (after success or failure)
    func clearPendingRestore(_ taskIds: [String]) {
        pendingRestoreIds.subtract(taskIds)
    }

    // MARK: - Loading States

    /// Start loading todos
    func startLoading() {
        isLoading = true
        errorMessage = nil
    }

    /// Handle load error
    func setError(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    /// Start loading backlog
    func startBacklogLoading() {
        isBacklogLoading = true
    }

    // MARK: - UI Actions

    /// Show the todo sheet
    func show() {
        showSheet = true
    }

    /// Dismiss the todo sheet
    func dismiss() {
        showSheet = false
    }

    /// Toggle backlog expansion
    func toggleBacklog() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isBacklogExpanded.toggle()
        }
    }

    // MARK: - Cleanup

    /// Clear all state (for new session)
    func clearAll() {
        todos.removeAll()
        summary = ""
        backlogTasks.removeAll()
        pendingRestoreIds.removeAll()
        isLoading = false
        isBacklogLoading = false
        errorMessage = nil
        isBacklogExpanded = false
        showSheet = false
    }

    /// Clear session-specific state only (keep backlog for workspace)
    func clearSessionTodos() {
        todos.removeAll()
        summary = ""
        isLoading = false
        errorMessage = nil
    }
}
