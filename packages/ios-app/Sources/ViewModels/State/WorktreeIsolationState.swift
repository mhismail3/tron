import Foundation

/// Manages worktree isolation state for ChatViewModel.
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
