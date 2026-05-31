import Foundation

/// Session-scoped view over `WorktreeStatusCache`.
///
/// Keeps the chat toolbar's bindings (`worktree`, `hasWorktree`) unchanged
/// while delegating storage to the shared cache, so the sidebar row and the
/// toolbar observe the same state.
@Observable
@MainActor
final class WorktreeIsolationState {
    let sessionId: String
    let cache: WorktreeStatusCache

    var isLoading = false

    init(sessionId: String, cache: WorktreeStatusCache) {
        self.sessionId = sessionId
        self.cache = cache
    }

    var status: WorktreeGetStatusResult? { cache.status(for: sessionId) }
    var hasWorktree: Bool { status?.hasIsolatedWorktree ?? false }
    var worktree: WorktreeInfo? { status?.worktree }
}
