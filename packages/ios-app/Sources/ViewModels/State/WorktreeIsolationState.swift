import Foundation

/// Manages worktree isolation state for ChatViewModel.
/// Follows the same extracted-state pattern as BrowserState, TaskState, etc.
@Observable
@MainActor
final class WorktreeIsolationState {
    /// Current worktree status from server
    var status: WorktreeGetStatusResult?

    /// Whether an API call is in flight
    var isLoading = false

    /// Whether this session has an active worktree
    var hasWorktree: Bool {
        status?.hasWorktree ?? false
    }

    /// The worktree info (nil if no worktree)
    var worktree: WorktreeInfo? {
        status?.worktree
    }

    init() {}
}
