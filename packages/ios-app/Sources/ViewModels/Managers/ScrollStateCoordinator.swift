import SwiftUI

/// Scroll state coordinator using `onScrollPhaseChange` for definitive user-scroll detection.
/// Replaces geometry-inference heuristics with phase-based knowledge of whether the user is dragging.
@Observable
@available(iOS 18.0, *)
@MainActor
final class ScrollStateCoordinator {

    // MARK: - State

    /// Whether the scroll view is near the bottom of its content
    private(set) var isAtBottom = true

    /// Whether the user has actively scrolled away from bottom.
    /// Only set by user drag gestures, never by programmatic scroll or layout changes.
    private(set) var userScrolledAway = false

    /// Whether the user is currently interacting with the scroll view
    private var isUserInteracting = false

    // MARK: - History Loading

    private var anchoredItemId: UUID?

    // MARK: - Scroll Phase

    /// Call from onScrollPhaseChange — tells us definitively if user is dragging
    func scrollPhaseChanged(from oldPhase: ScrollPhase, to newPhase: ScrollPhase) {
        let wasUserInteracting = isUserInteracting
        isUserInteracting = newPhase == .interacting || newPhase == .tracking || newPhase == .decelerating

        // When user interaction ends (decelerating → idle), evaluate final position
        if wasUserInteracting && !isUserInteracting {
            if isAtBottom {
                userScrolledAway = false
            }
        }
    }

    // MARK: - Geometry Updates

    /// Call from onScrollGeometryChange — just tracks isAtBottom, nothing more
    func geometryChanged(isNearBottom: Bool) {
        isAtBottom = isNearBottom

        // If user is interacting and scrolled away from bottom, mark it
        if isUserInteracting && !isNearBottom {
            userScrolledAway = true
        }

        // If we're at bottom (regardless of how we got here), clear the flag
        if isNearBottom {
            userScrolledAway = false
        }
    }

    // MARK: - User Actions

    func userSentMessage() {
        userScrolledAway = false
    }

    func userTappedScrollToBottom() {
        userScrolledAway = false
    }

    // MARK: - History Loading

    func willPrependHistory(firstVisibleId: UUID?) {
        anchoredItemId = firstVisibleId
    }

    func didPrependHistory(using proxy: ScrollViewProxy?) {
        if let id = anchoredItemId {
            proxy?.scrollTo(id, anchor: .top)
            anchoredItemId = nil
        }
    }

    // MARK: - Navigation

    func scrollToTarget(messageId: UUID, using proxy: ScrollViewProxy?) {
        userScrolledAway = true
        withAnimation(.easeOut(duration: 0.3)) {
            proxy?.scrollTo(messageId, anchor: .center)
        }
    }

    // MARK: - Query

    /// Whether to auto-scroll on new content
    var shouldAutoScroll: Bool {
        !userScrolledAway
    }

    /// Whether to show the "New Content" pill.
    /// Caller must also check isProcessing — pill only shows during active streaming.
    var shouldShowNewContentPill: Bool {
        userScrolledAway
    }
}
