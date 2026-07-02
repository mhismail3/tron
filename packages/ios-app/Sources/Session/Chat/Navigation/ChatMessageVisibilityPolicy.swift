import Foundation

/// Determines whether a chat row should be visible while the initial scroll
/// and optional cascade animation settle.
enum ChatMessageVisibilityPolicy {
    static func isVisible(
        index: Int,
        total: Int,
        initialLoadComplete: Bool,
        hasReconstructedState: Bool,
        isCascading: Bool,
        cascadeAllowsVisibility: Bool
    ) -> Bool {
        guard total > 0 else { return false }

        // Once server reconstruction has produced a real transcript, fail open.
        // A stale view-local initial-load flag must never hide all chat history.
        if hasReconstructedState && !isCascading {
            return true
        }

        if isCascading || !initialLoadComplete {
            return cascadeAllowsVisibility
        }

        return true
    }
}
